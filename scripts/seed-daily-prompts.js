#!/usr/bin/env node
/**
 * seed-daily-prompts.js
 *
 * Bulk-replaces Skadoodle's `daily_prompts` Firestore collection from a
 * plain text file of subjects. This is the "real" version of the in-app
 * DEBUG seeder (SettingsTab.seedDailyPromptsIfDebug) — that one only fills
 * in dates that don't have a doc yet, which is right for topping up the
 * calendar but useless if you just don't like the pool anymore ("sandwich"
 * lol). This script OVERWRITES every future date instead.
 *
 * Why overwriting the future is safe:
 *   - Nothing in the app ever fetches or displays a FUTURE date's subject —
 *     only `todaySubject` (today) and `yesterdaySubject` (yesterday) are
 *     ever read (see DailyManager in SnoodleFirebase.swift). So no user has
 *     ever seen tomorrow's or later's assignment, and overwriting it can't
 *     retroactively change something someone already saw.
 *   - This script never touches today's doc or anything in the past —
 *     it always starts at tomorrow.
 *
 * ---- ONE-TIME SETUP ----
 * 1. Firebase Console → Project Settings → Service Accounts →
 *    "Generate new private key". Save the JSON file OUTSIDE any git repo
 *    (e.g. ~/secrets/skadoodle-service-account.json). Do NOT commit this
 *    file anywhere — it grants full admin access to the whole project.
 * 2. cd into this scripts/ folder and run: npm install firebase-admin
 *
 * ---- USAGE ----
 *   node seed-daily-prompts.js <subjects.txt> <service-account.json> [--days=400] [--dry-run]
 *
 * ---- SUBJECTS FILE FORMAT ----
 * One subject per line. Category is optional, after a pipe:
 *   Sandwich
 *   Dragon | Fantasy & Magic
 *   Rocket Ship|Space & Sci-Fi
 * Blank lines and lines starting with # are ignored. Category isn't read
 * by the app yet (it's there for a future admin-panel UI to group by), so
 * leaving it off is fine.
 *
 * The list is shuffled and assigned one-per-day starting tomorrow. If the
 * horizon (--days, default 400 — matches the in-app seeder's default) is
 * longer than the list, it re-shuffles and cycles through again rather than
 * repeating in the same order every lap.
 */

const fs = require("fs");
const path = require("path");

function parseArgs(argv) {
  const positional = [];
  const flags = { days: 400, dryRun: false };
  for (const arg of argv) {
    if (arg === "--dry-run") flags.dryRun = true;
    else if (arg.startsWith("--days=")) flags.days = parseInt(arg.split("=")[1], 10);
    else positional.push(arg);
  }
  return { positional, flags };
}

function loadSubjects(filePath) {
  const raw = fs.readFileSync(filePath, "utf8");
  const subjects = [];
  for (const rawLine of raw.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const [subjectPart, categoryPart] = line.split("|");
    const subject = subjectPart.trim();
    const category = (categoryPart || "").trim();
    if (subject) subjects.push({ subject, category });
  }
  return subjects;
}

// Fisher-Yates. Mutates and returns a new shuffled copy.
function shuffle(arr) {
  const a = arr.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

// Same doc-ID format the app uses everywhere: DailyEntry.contestDateString,
// pinned to America/New_York (handles EST/EDT automatically).
function contestDateString(date) {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/New_York",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(date);
}

async function main() {
  const { positional, flags } = parseArgs(process.argv.slice(2));
  const [subjectsPath, serviceAccountPath] = positional;

  if (!subjectsPath || !serviceAccountPath) {
    console.error(
      "Usage: node seed-daily-prompts.js <subjects.txt> <service-account.json> [--days=400] [--dry-run]"
    );
    process.exit(1);
  }

  const subjects = loadSubjects(path.resolve(subjectsPath));
  if (subjects.length === 0) {
    console.error("No subjects found in file — nothing to do.");
    process.exit(1);
  }
  console.log(`Loaded ${subjects.length} subject(s) from ${subjectsPath}`);

  const todayStr = contestDateString(new Date());
  const assignments = []; // { date, subject, category }
  let pool = shuffle(subjects);
  let poolIdx = 0;

  for (let i = 1; i <= flags.days; i++) {
    const date = new Date(Date.now() + i * 86400000);
    const dateStr = contestDateString(date);
    if (dateStr <= todayStr) continue; // never touch today or the past

    if (poolIdx >= pool.length) {
      pool = shuffle(subjects); // reshuffle each fresh lap through the list
      poolIdx = 0;
    }
    assignments.push({ date: dateStr, ...pool[poolIdx] });
    poolIdx++;
  }

  console.log(
    `Will assign ${assignments.length} date(s), from ${assignments[0].date} to ${assignments[assignments.length - 1].date}.`
  );

  if (flags.dryRun) {
    console.log("--dry-run set — showing first 10, no writes will happen:");
    assignments.slice(0, 10).forEach((a) => console.log(`  ${a.date}: ${a.subject}${a.category ? " (" + a.category + ")" : ""}`));
    return;
  }

  const admin = require("firebase-admin");
  admin.initializeApp({
    credential: admin.credential.cert(require(path.resolve(serviceAccountPath))),
  });
  const db = admin.firestore();

  // Firestore batches cap at 500 writes — chunk to be safe.
  const chunkSize = 400;
  for (let start = 0; start < assignments.length; start += chunkSize) {
    const chunk = assignments.slice(start, start + chunkSize);
    const batch = db.batch();
    for (const a of chunk) {
      const ref = db.collection("daily_prompts").doc(a.date);
      batch.set(ref, { subject: a.subject, category: a.category });
    }
    await batch.commit();
    console.log(`Wrote ${chunk.length} doc(s) (${start + chunk.length}/${assignments.length})`);
  }

  console.log("Done.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
