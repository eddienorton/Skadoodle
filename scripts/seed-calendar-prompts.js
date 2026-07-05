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
 * SETUP: npm install firebase-admin  (in this scripts/ folder)
 * USAGE: node seed-calendar-prompts.js <service-account.json> [--days=400] [--dry-run]
 */

const path = require("path");

// MM-DD -> [subject, category]. Add more months here as they get drafted.
const CALENDAR = {
  "07-01": ["Fresh Start", "Seasonal"],
  "07-02": ["Poolside", "Seasonal"],
  "07-03": ["Fireflies", "Seasonal"],
  "07-04": ["Fireworks", "Holiday"],
  "07-05": ["Sparkler", "Seasonal"],
  "07-06": ["Sunburn", "Seasonal"],
  "07-07": ["Lazy Heat", "Seasonal"],
  "07-08": ["Watermelon", "Seasonal"],
  "07-09": ["Road Trip", "Seasonal"],
  "07-10": ["Sprinkler", "Seasonal"],
  "07-11": ["Ice Cream Truck", "Seasonal"],
  "07-12": ["Thunderstorm", "Seasonal"],
  "07-13": ["Campfire", "Seasonal"],
  "07-14": ["Flip Flops", "Seasonal"],
  "07-15": ["Lemonade Stand", "Seasonal"],
  "07-16": ["Dog Days", "Seasonal"],
  "07-17": ["Sandcastle", "Seasonal"],
  "07-18": ["Sunscreen", "Seasonal"],
  "07-19": ["Cannonball", "Seasonal"],
  "07-20": ["Porch Swing", "Seasonal"],
  "07-21": ["Midsummer", "Seasonal"],
  "07-22": ["Tan Lines", "Seasonal"],
  "07-23": ["Popsicle", "Seasonal"],
  "07-24": ["Star Gazing", "Seasonal"],
  "07-25": ["County Fair", "Seasonal"],
  "07-26": ["BBQ", "Seasonal"],
  "07-27": ["Mosquito Bite", "Seasonal"],
  "07-28": ["Beach Day", "Seasonal"],
  "07-29": ["Sunset Swim", "Seasonal"],
  "07-30": ["Summer Storm", "Seasonal"],
  "07-31": ["Dog Tired", "Seasonal"],
};

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
  const [serviceAccountPath] = positional;

  if (!serviceAccountPath) {
    console.error("Usage: node seed-calendar-prompts.js <service-account.json> [--days=400] [--dry-run]");
    process.exit(1);
  }

  const todayStr = contestDateString(new Date());
  const assignments = [];

  for (let i = 1; i <= flags.days; i++) {
    const date = new Date(Date.now() + i * 86400000);
    const dateStr = contestDateString(date);
    if (dateStr <= todayStr) continue; // never touch today or the past

    const mmdd = dateStr.slice(5); // "MM-DD"
    const entry = CALENDAR[mmdd];
    if (!entry) continue; // not drafted yet — leave it for the app's fallback

    assignments.push({ date: dateStr, subject: entry[0], category: entry[1] });
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
