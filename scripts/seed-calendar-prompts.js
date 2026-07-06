#!/usr/bin/env node
/**
 * seed-calendar-prompts.js
 *
 * Seeds `daily_prompts` from a MM-DD calendar (repeats every year — same
 * subject on the same calendar day, forever) instead of a shuffled pool.
 * Only writes dates whose MM-DD is present in CALENDAR below — every other
 * date is left untouched, so the app's existing fallback (random pool /
 * mod-cycle formula) keeps covering any month we haven't drafted yet.
 * Safe to re-run any time as more months get added to CALENDAR below.
 *
 * Never touches today or the past (same rule as seed-daily-prompts.js).
 *
 * Only writes THIS calendar year by default (tomorrow through Dec 31) — it
 * never needs to write next year, or any year after that. The app's
 * `fetchSubject(for:)` (SnoodleFirebase.swift) already walks backward year by
 * year looking for a match, so 2027, 2028, etc. all automatically inherit
 * whatever's seeded in the current baseline year with zero extra writes.
 * Seeding next year's dates too would just be redundant duplication of the
 * same content — harmless, but pointless, and confusing to look at in the
 * console (a partially-written future year that looks broken but isn't).
 * Pass --days=N to explicitly override the horizon if you ever have a real
 * reason to reach further (e.g. deliberately overriding one specific future
 * date, though for a single date the Firebase Console is probably simpler).
 *
 * --allow-past: also backfills Jan 1 of the current year through yesterday
 * (never today itself). Normally writing past dates is unsafe — it would
 * rewrite the historical record of a concluded contest day. This flag is
 * safe ONLY because Daily Doodle's real history begins July 5, 2026 (see
 * "daily_gallery reset for launch" in CLAUDE.md) — nothing before that date
 * was ever a real contest day, so there's no real history to overwrite for
 * Jan–June. Do not reuse this flag once the app has real users experiencing
 * daily contests across a full year — at that point every date, past or
 * future, is either already seeded or genuinely locked history.
 *
 * The actual subject list lives in daily-prompts-calendar.json, right next to
 * this script — open that file directly to see or hand-edit the whole
 * calendar. This file is just the logic that reads it and writes to Firestore.
 *
 * SETUP: npm install firebase-admin  (in this scripts/ folder)
 * USAGE: node seed-calendar-prompts.js <service-account.json> [--days=N] [--allow-past] [--dry-run]
 */

const path = require("path");

// MM-DD -> [subject, category]. Add more months to daily-prompts-calendar.json
// as they get drafted — nothing in this file needs to change.
const CALENDAR = require("./daily-prompts-calendar.json");

function parseArgs(argv) {
  const positional = [];
  const flags = { days: null, dryRun: false, allowPast: false };
  for (const arg of argv) {
    if (arg === "--dry-run") flags.dryRun = true;
    else if (arg === "--allow-past") flags.allowPast = true;
    else if (arg.startsWith("--days=")) flags.days = parseInt(arg.split("=")[1], 10);
    else positional.push(arg);
  }
  return { positional, flags };
}

function contestDateString(date) {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/New_York",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(date);
}

// Days from tomorrow through Dec 31 of the current year — the default
// horizon, since that's genuinely all that ever needs seeding (see the
// header comment above for why next year is never required).
function daysRemainingInYear(now) {
  const todayStr = contestDateString(now);
  const year = parseInt(todayStr.slice(0, 4), 10);
  const dec31Str = `${year}-12-31`;
  let count = 0;
  for (let i = 1; i <= 366; i++) {
    const date = new Date(now.getTime() + i * 86400000);
    const dateStr = contestDateString(date);
    count = i;
    if (dateStr >= dec31Str) break;
  }
  return count;
}

async function main() {
  const { positional, flags } = parseArgs(process.argv.slice(2));
  const [serviceAccountPath] = positional;

  if (!serviceAccountPath) {
    console.error("Usage: node seed-calendar-prompts.js <service-account.json> [--days=N] [--dry-run]");
    process.exit(1);
  }

  const now = new Date();
  const todayStr = contestDateString(now);
  const horizon = flags.days ?? daysRemainingInYear(now);
  console.log(`Horizon: ${horizon} day(s)${flags.days ? " (explicit --days override)" : " (through Dec 31 of this year)"}`);
  const assignments = [];

  for (let i = 1; i <= horizon; i++) {
    const date = new Date(now.getTime() + i * 86400000);
    const dateStr = contestDateString(date);
    if (dateStr <= todayStr) continue; // never touch today or the past

    const mmdd = dateStr.slice(5); // "MM-DD"
    const entry = CALENDAR[mmdd];
    if (!entry) continue; // not drafted yet — leave it for the app's fallback

    assignments.push({ date: dateStr, subject: entry[0], category: entry[1] });
  }

  if (flags.allowPast) {
    // Backfill Jan 1 of this year through yesterday. Safe only because
    // Daily Doodle's real history starts July 5, 2026 — see header comment.
    const year = parseInt(todayStr.slice(0, 4), 10);
    const jan1 = `${year}-01-01`;
    let d = new Date(`${jan1}T12:00:00`); // noon avoids DST-edge date-shift issues
    let count = 0;
    while (true) {
      const dateStr = contestDateString(d);
      if (dateStr >= todayStr) break; // stop before today, never touch today
      const mmdd = dateStr.slice(5);
      const entry = CALENDAR[mmdd];
      if (entry) assignments.push({ date: dateStr, subject: entry[0], category: entry[1] });
      d = new Date(d.getTime() + 86400000);
      count++;
      if (count > 200) break; // safety valve, Jan 1 -> ~Jul 5 is ~185 days
    }
    console.log(`--allow-past set — also backfilling ${jan1} through the day before today.`);
  }

  console.log(`${assignments.length} date(s) matched the calendar so far:`);
  assignments.forEach((a) => console.log(`  ${a.date}: ${a.subject} (${a.category})`));

  if (flags.dryRun) {
    console.log("--dry-run set — no writes made.");
    return;
  }

  const admin = require("firebase-admin");
  admin.initializeApp({
    credential: admin.credential.cert(require(path.resolve(serviceAccountPath))),
  });
  const db = admin.firestore();

  const batch = db.batch();
  for (const a of assignments) {
    batch.set(db.collection("daily_prompts").doc(a.date), { subject: a.subject, category: a.category });
  }
  await batch.commit();
  console.log(`Wrote ${assignments.length} doc(s). Done.`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
