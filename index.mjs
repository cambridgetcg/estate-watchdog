// estate-watchdog — weekly read-only sweep of the AWS estate → SNS email.
// Runtime: nodejs22.x. Uses the AWS SDK v3 bundled in the Lambda runtime (no deps to package).
import { EC2Client, DescribeSecurityGroupsCommand, DescribeAddressesCommand } from "@aws-sdk/client-ec2";
import { RDSClient, DescribeDBInstancesCommand, DescribeDBSnapshotsCommand } from "@aws-sdk/client-rds";
import { CostExplorerClient, GetCostAndUsageCommand } from "@aws-sdk/client-cost-explorer";
import { SNSClient, PublishCommand } from "@aws-sdk/client-sns";

const REGIONS = (process.env.REGIONS || "us-east-1,us-west-2,eu-west-1,eu-west-2,eu-north-1,ap-southeast-2").split(",");
const TOPIC_ARN = process.env.TOPIC_ARN;

async function scanRegion(region) {
  const out = [];
  const ec2 = new EC2Client({ region });
  const rds = new RDSClient({ region });

  try {
    const sgs = await ec2.send(new DescribeSecurityGroupsCommand({ Filters: [{ Name: "ip-permission.cidr", Values: ["0.0.0.0/0"] }] }));
    for (const sg of sgs.SecurityGroups ?? []) {
      const ports = (sg.IpPermissions ?? [])
        .filter((p) => (p.IpRanges ?? []).some((r) => r.CidrIp === "0.0.0.0/0"))
        .map((p) => (p.FromPort === p.ToPort ? p.FromPort : `${p.FromPort}-${p.ToPort}`) ?? "all");
      // 80/443 are normal public web tiers — only flag database/admin/odd ports
      const risky = ports.filter((p) => ![80, 443].includes(p));
      if (risky.length) out.push(`🔓 ${sg.GroupId} (${sg.GroupName}) open to world: ${risky.join(", ")}`);
    }
  } catch (e) { out.push(`⚠️ SG scan failed: ${e.name}`); }

  try {
    const dbs = await rds.send(new DescribeDBInstancesCommand({}));
    for (const d of dbs.DBInstances ?? [])
      if (d.PubliclyAccessible) out.push(`🌐 RDS ${d.DBInstanceIdentifier} PubliclyAccessible${d.StorageEncrypted ? "" : " + UNENCRYPTED"}`);
  } catch (e) { out.push(`⚠️ RDS scan failed: ${e.name}`); }

  try {
    const eips = await ec2.send(new DescribeAddressesCommand({}));
    for (const a of eips.Addresses ?? [])
      if (!a.AssociationId) out.push(`💸 Elastic IP ${a.PublicIp} unassociated (~$3.6/mo idle)`);
  } catch (e) { out.push(`⚠️ EIP scan failed: ${e.name}`); }

  try {
    const snaps = await rds.send(new DescribeDBSnapshotsCommand({ SnapshotType: "manual" }));
    const live = new Set();
    const dbs2 = await rds.send(new DescribeDBInstancesCommand({}));
    for (const d of dbs2.DBInstances ?? []) live.add(d.DBInstanceIdentifier);
    const orphans = (snaps.DBSnapshots ?? []).filter((s) => !live.has(s.DBInstanceIdentifier));
    const gb = orphans.reduce((n, s) => n + (s.AllocatedStorage || 0), 0);
    if (orphans.length) out.push(`🗄️ ${orphans.length} orphan manual RDS snapshots (~${gb}GB) of deleted DBs`);
  } catch (e) { /* snapshot perms optional */ }

  return out;
}

async function costSummary() {
  try {
    const ce = new CostExplorerClient({ region: "us-east-1" });
    const now = new Date();
    const iso = (d) => d.toISOString().slice(0, 10);
    const startPrev = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 1, 1));
    const today = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
    if (iso(today) === iso(new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)))) return null; // 1st of month
    const r = await ce.send(new GetCostAndUsageCommand({
      TimePeriod: { Start: iso(startPrev), End: iso(today) },
      Granularity: "MONTHLY",
      Metrics: ["UnblendedCost"],
    }));
    const months = (r.ResultsByTime ?? []).map((p) => ({
      m: p.TimePeriod.Start.slice(0, 7),
      amt: parseFloat(p.Total.UnblendedCost.Amount),
    }));
    return months.map((x) => `${x.m}: $${x.amt.toFixed(2)}`).join("  |  ");
  } catch (e) { return `cost lookup failed: ${e.name}`; }
}

export const handler = async () => {
  const sections = [];
  for (const region of REGIONS) {
    const f = await scanRegion(region);
    sections.push(`### ${region}\n${f.length ? f.map((x) => "  " + x).join("\n") : "  ✓ clean"}`);
  }
  const cost = await costSummary();
  const flagged = sections.filter((s) => !s.includes("✓ clean")).length;

  const body = [
    `Estate Watchdog — ${new Date().toISOString().slice(0, 16)}Z`,
    `Account 034362054546 · ${flagged}/${REGIONS.length} regions with findings`,
    cost ? `\nSpend (prev month | MTD):  ${cost}` : "",
    "",
    sections.join("\n\n"),
    "",
    "— read-only sweep. Fix anything 🔓/🌐/💸 from your Mac (aleph or aws CLI).",
  ].join("\n");

  if (TOPIC_ARN) {
    const sns = new SNSClient({ region: process.env.AWS_REGION || "us-east-1" });
    await sns.send(new PublishCommand({
      TopicArn: TOPIC_ARN,
      Subject: `🏰 Estate Watchdog — ${flagged} region(s) flagged`,
      Message: body,
    }));
  }
  return { statusCode: 200, flagged, body };
};
