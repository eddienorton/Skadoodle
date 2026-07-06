#!/usr/bin/env node
/**
 * delete-non-baseline-daily-prompts.js
 *
 * One-off cleanup: deletes every `daily_prompts` doc whose year isn't the
 * baseline year (2026 by default — must match subjectLookbackFloorYear in
 * SnoodleFirebase.swift). Now that fetchSubject(for:) walks backward year by
 * year to inherit content, nothing outside the baseline year is ever
 * actually read by the app — any doc dated a different year is dead weight,
 * whether it's a leftover from the old 400-day-horizon calendar runs (which
 * wrote into 2027 before that default was fixed) or from the very first
 * flat-pool debug seeding (which filled ~400 days forward from whenever it
 * was first run, covering parts of 2027 with old random-pool content too).
 *
 * SAFE: scans the whole collection, only ever deletes docs whose ID's year
 * doesn't match --keep-year. Never touches the baseline year itself.
 *
 * USAGE: node delete-non-baseline-daily-prompts.js <service-account.json> [--keep-year=2026] [--dry-run]
 */

const path = require("path");

function parseArgs(argv) {
  const positional = [];
  const flags = { keepYear: 2026, dryRun: false };
  for (const arg of argv) {
    if (arg === "--dry-run") flags.dryRun = true;
    else if (arg.startsWith("--keep-year=")) flags.keepYear = parseInt(arg.split("=")[1], 10);
    else positional.push(arg);
  }
  return { positional, flags };
}

async function main() {
  const { positional, flags } = parseArgs(process.argv.slice(2));
  const [serviceAccountPath] = positional;

  if (!serviceAccountPath) {
    console.error("Usage: node delete-non-baseline-daily-prompts.js <service-account.json> [--keep-year=2026] [--dry-run]");
    process.exit(1);
  }

  const admin = require("firebase-admin");
  admin.initializeApp({
    credential: admin.credential.cert(require(path.resolve(serviceAccountPath))),
  });
  const db = admin.firestore();

  const snap = await db.collection("daily_prompts").get();
  const toDelete = [];
  snap.forEach((doc) => {
    const match = doc.id.match(/^(\d{4})-\d{2}-\d{2}$/);
    if (!match) return; // skip anything not in the expected YYYY-MM-DD format
    const year = parseInt(match[1], 10);
    if (year !== flags.keepYear) toDelete.push(doc.id);
  });
  toDelete.sort();

  console.log(`${toDelete.length} doc(s) outside ${flags.keepYear} found:`);
  toDelete.forEach((id) => console.log(`  ${id}`));

  if (toDelete.length === 0) {
    console.log("Nothing to delete — already clean.");
    return;
  }

  if (flags.dryRun) {
    console.log("--dry-run set — nothing deleted.");
    return;
  }

  const chunkSize = 400; // Firestore batch cap is 500 writes — stay safely under it
  for (let start = 0; start < toDelete.length; start += chunkSize) {
    const chunk = toDelete.slice(start, start + chunkSize);
    const batch = db.batch();
    for (const id of chunk) {
      batch.delete(db.collection("daily_prompts").doc(id));
    }
    await batch.commit();
    console.log(`Deleted ${chunk.length} doc(s) (${start + chunk.length}/${toDelete.length})`);
  }
  console.log("Done.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
