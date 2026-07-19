#!/usr/bin/env node
/**
 * backfill-joined-at.js
 *
 * One-off backfill: `joinedAt` was never written to `users` docs before the
 * fix landed in SnoodleFirebase.swift (UserProfileManager's new-user creation
 * block). Every existing user's doc is missing the field, and the app's own
 * read-side fallback (parseProfile: `data["joinedAt"] ?? Date()`) silently
 * reports "now" every time it's read rather than surfacing the gap.
 *
 * This script scans `users`, and for any doc missing `joinedAt`, sets it to
 * that doc's own `updatedAt` value — not exact (an early edit event, not the
 * true signup moment), but the closest approximation available, since
 * `updatedAt` has been ticking since close to when each account was created.
 *
 * Docs that already have `joinedAt` are left untouched — safe to re-run.
 * Docs missing BOTH `joinedAt` and `updatedAt` (shouldn't happen given
 * `updatedAt` is written at creation and on every edit, but handled
 * defensively) are skipped and logged rather than guessing a fake date.
 *
 * USAGE: node backfill-joined-at.js <service-account.json> [--dry-run]
 */

const path = require("path");

function parseArgs(argv) {
  const positional = [];
  const flags = { dryRun: false };
  for (const arg of argv) {
    if (arg === "--dry-run") flags.dryRun = true;
    else positional.push(arg);
  }
  return { positional, flags };
}

async function main() {
  const { positional, flags } = parseArgs(process.argv.slice(2));
  const [serviceAccountPath] = positional;

  if (!serviceAccountPath) {
    console.error("Usage: node backfill-joined-at.js <service-account.json> [--dry-run]");
    process.exit(1);
  }

  const admin = require("firebase-admin");
  admin.initializeApp({
    credential: admin.credential.cert(require(path.resolve(serviceAccountPath))),
  });
  const db = admin.firestore();

  const snap = await db.collection("users").get();

  const toBackfill = []; // { id, updatedAt }
  const skippedNoUpdatedAt = [];
  let alreadyHasJoinedAt = 0;

  snap.forEach((doc) => {
    const data = doc.data();
    if (data.joinedAt) {
      alreadyHasJoinedAt++;
      return;
    }
    if (!data.updatedAt) {
      skippedNoUpdatedAt.push(doc.id);
      return;
    }
    toBackfill.push({ id: doc.id, updatedAt: data.updatedAt });
  });

  console.log(`${snap.size} total user doc(s)`);
  console.log(`${alreadyHasJoinedAt} already have joinedAt — left alone`);
  console.log(`${toBackfill.length} missing joinedAt, will backfill from updatedAt`);
  if (skippedNoUpdatedAt.length > 0) {
    console.log(`${skippedNoUpdatedAt.length} missing BOTH joinedAt and updatedAt — skipped, not guessing:`);
    skippedNoUpdatedAt.forEach((id) => console.log(`  ${id}`));
  }

  if (toBackfill.length === 0) {
    console.log("Nothing to backfill.");
    return;
  }

  if (flags.dryRun) {
    console.log("--dry-run set — showing first 10, nothing written:");
    toBackfill.slice(0, 10).forEach((u) => {
      console.log(`  ${u.id} -> joinedAt = ${u.updatedAt.toDate().toISOString()}`);
    });
    return;
  }

  const chunkSize = 400; // Firestore batch cap is 500 writes — stay safely under it
  for (let start = 0; start < toBackfill.length; start += chunkSize) {
    const chunk = toBackfill.slice(start, start + chunkSize);
    const batch = db.batch();
    for (const u of chunk) {
      batch.update(db.collection("users").doc(u.id), { joinedAt: u.updatedAt });
    }
    await batch.commit();
    console.log(`Backfilled ${chunk.length} doc(s) (${start + chunk.length}/${toBackfill.length})`);
  }
  console.log("Done.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
