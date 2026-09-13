# User Manual & Administrator Guide — PawTrace (AI Dog Finder 2.0)

| Field | Value |
|---|---|
| Document ID | UM-07-PawTrace |
| Version | 1.0 (Draft) |
| Date | 2026-09-13 |
| Author | Suphot N. |
| Status | Draft for review |
| Related | [SRS-07](../SRS-PawTrace-AI-Dog-Finder.md) · [SAD-07](SAD-PawTrace-Software-Architecture.md) · [API-07](../api/API-Specification.md) · [OPS-07](OPS-PawTrace-Deployment-Operations.md) · [SEC-07](SEC-PawTrace-Security-Requirements.md) |
| Audience | Part A: dog owners, finders, shelter volunteers, moderators. Part B: administrators |
| Languages | The app is in Thai and English (NFR-09). This manual is in English; Part C gives the Thai terms used on screen |

---

# Part A — User guide

## A0. Read this first (everyone)

PawTrace helps people find lost dogs by comparing photos, places and times. Three things it deliberately does **not** do:

1. **It never says "this is your dog."** It shows *possible sightings* with a number — for example **"68 % of possible sightings like this one turned out to be right."** That number comes from what other owners confirmed in the past, not from how similar the photos look. You look at the photos side by side and you decide.
2. **It never shows anyone where you live.** The public map and other people's screens show an area of about 5 × 5 km, never a point. Your exact location is seen only by you — and, if you choose, by the one person you are arranging to meet, after both of you agree.
3. **It never gives your email or phone number to anyone.** You talk through the app. If you want to share a number, you type it yourself, and the app will remind you to be careful.

Safety: when you go to meet someone about a dog, go in daylight, to a public place, and bring someone with you. Nobody who has your dog needs to know your address.

## A1. Dog owner — "I lost my dog"

### A1.1 Posting
1. **Sign in** with your email — you get a link, no password. Accept the terms (they say how your confirm/reject answers may be used to improve the system; you can delete everything later).
2. **Post → I lost my dog.** Add 1–10 photos (clear, the dog filling the frame, different angles help). Set **where** (GPS, drop a pin, or type an address) and **when**. Describe colour, size, coat, collar, name.
3. The app checks each photo: *no dog found*, *too small*, *too blurry* means that photo will not help — replace it. Photos are stripped of hidden data (camera location, device) before they are saved.
4. Within seconds to a minute you see **Possible sightings** — or "photos still being processed" if the system is busy. Your post is live either way.

### A1.2 Reading a possible sighting
```
Possible sighting  ·  68 % of sightings like this were confirmed
[ your photo ]   [ their photo ]
about 2 km away · seen 35 hours after you lost Latte · brown · medium · short coat
Why this score: photo similarity high · colour/size match · close by · time plausible
```
| Line | Meaning |
|---|---|
| **68 % … were confirmed** | Of past possible sightings with a similar score, 68 % were confirmed by their owners. It is not a photo-similarity percentage and not a guarantee |
| **about 2 km away** | A distance band, not a point. The exact spot is shared only after you both agree (A1.4) |
| **seen 35 hours after** | Time since you lost the dog. A sighting *before* you lost the dog is unlikely to be yours (unless the dog has been lost before — tick *re-loss* when posting) |
| **Why this score** | The four ingredients: photo similarity, colour/size/coat agreement, distance, time. A high score that is mostly "close by" deserves a careful look at the photos |
| **Details** | Shows the raw numbers, including photo similarity. Do not treat similarity as "the score" |

### A1.3 Confirm or reject
- **That's my dog** → the sighting is marked confirmed and a **chat** opens with the finder.
- **Not my dog** → it disappears from your list and will not come back. Your answer helps the system show better sightings to the next owner (it is stored without your name).
- You are notified of new possible sightings by push or email — **at most 5 a day**; the rest are collected in an evening summary so your phone does not buzz all night.

### A1.4 Chatting and meeting
The chat shows no phone numbers or emails. To share where exactly the dog was seen, **both** of you tap *Share exact location*; until then each side sees only the area. Meet safely (A0). If someone asks for money before showing you the dog, report the chat.

### A1.5 Reunited
Tap **Reunited** on the confirmed sighting. Your post closes; other possible sightings are dismissed; you can write a short story and choose whether to share it publicly (without location).

### A1.6 Your data
**Settings → My data**: download everything, or delete everything — posts, photos, the system's derived data from your photos, chats. Deletion starts immediately and finishes within 72 hours.

## A2. Finder — "I saw a dog"
1. Open the app — **no account needed**. Tap **I saw a dog**.
2. Take **one photo** (or choose one), let the app use your **location** (or drop a pin), check the **time** (pre-filled with now), tap **Post**. Under a minute.
3. That is it. Owners nearby with a similar dog are notified once the photo has been checked. If an owner confirms, a chat opens in the app; you will see it under **My posts** on this phone.
4. You are never asked for your name, email or phone. If you post many times quickly, the app may ask you to solve a quick puzzle (it stops spam).
5. If you can, stay near the dog or note where it went; do not chase it.

**Search by photo**: if you have found a dog and want to check whether someone is looking for it, use **Search → by photo**; the results are possible matches in your area with the same kind of score.

## A3. Shelter volunteer
Sign in with the shelter account. **Intake**: upload a CSV (one row per dog: photo file name, intake time, location, size, colour, coat, breed group, notes) with a zip of photos — each row becomes a found-dog post from the shelter, processed like any other photo. **Search by photo** for every new intake; possible owners' posts appear with the score. Shelter posts show the shelter's area, not the exact address, to the public.

## A4. Moderator
**Queue** (priority order): abuse reports → photos held for review → duplicate posts.

| Action | When | Notes |
|---|---|---|
| Approve | photo held by the screen (score 0.6–0.9) and it is a normal dog photo | becomes visible |
| Hide | not a dog, unsafe, private information visible, spam | reversible; reason required |
| Remove | abusive/illegal content | not reversible for NSFW |
| Merge duplicates | the same dog posted twice within ~500 m and ~48 h | the earlier post stays; the other redirects |
| Ban device | flood, repeated fakes | the device can no longer post; a reason is recorded |

Every action is logged with your name and reason. You can read a chat **only** when someone reported it. Never share anything from a chat or a post outside the tool. Suspected luring (a "finder" pushing to meet at a private address, asking for money) → hide, ban, escalate (SEC-07 §7).

## A5. What the system never claims
- Never "match", "found", "identified" — only *possible sighting* and a confirmation rate.
- Never a point on the public map — cells of about 5 km.
- Never your contact details to anyone.
- Never a photo with hidden camera data.
- Never a decision on your behalf: you confirm, you reject, you mark reunited.

---

# Part B — Administrator guide

## B1. Roles
| Role | Can |
|---|---|
| Anonymous device | post sightings, search, report abuse, chat on its own confirmed sightings, delete its data |
| User | + post lost dogs, see possible sightings, confirm/reject, subscribe to an area |
| Shelter | + bulk intake |
| Moderator | + the queue, hide/remove/restore, merge, ban, read reported chats |
| Admin | + regions, thresholds, models, calibration, bias report, deletion requests, users' roles |

Nobody — including admins — can read another person's exact location through the app; it exists only in the owner's own view and in a chat after mutual consent (SEC-07 §5.8).

## B2. Regions and privacy settings
`pawtrace.yaml` → **Admin → Configuration** (validated on load; the schema refuses a public cell finer than ~5 km, a search radius above 50 km, more than 30 days, a daily notification cap of 0). Per region you may set the default radius and the daily cap. Every load is versioned; possible sightings and notifications show the version that produced them.

## B3. Thresholds
| Setting | Meaning | Guidance |
|---|---|---|
| `notify.threshold` (0.25) | minimum confirmation rate to notify | tuned for **recall** — owners would rather see an extra candidate than miss one; raise only if the cap is hit daily by many users |
| `notify.daily_cap` (5) | max alerts per person per day | a cap, not a tuning knob |
| `fusion.weights` | photo / attributes / distance / time | change only with the ML owner after a benchmark |
| `trust.*` | when to challenge or ban a device | from the weekly abuse review (OPS-07 §6.4) |
| `moderation.nsfw_*` | auto-hide and review bands | never auto-approve above 0.6 |

## B4. Models
**Admin → Models** lists versions with their benchmark (Recall@10 ≥ 0.80 required), re-embed progress and which one is *searchable*. Only one embedding version is searchable at a time; activating another is refused until its re-embed is complete. Never replace a model file in place — register a new version (OPS-07 §7). The **bias report** shows retrieval quality per coat colour and size; a gap above 15 % flags rebalancing.

## B5. Calibration
The confirmation rates shown to owners are recomputed nightly from confirm/reject answers. A new model starts with the previous curve, marked *provisional*, until 200 answers exist. Watch the drift metric; if the shown rate and the real rate diverge, refresh and review.

## B6. Moderation staffing and abuse
OPS-07 §6.3–6.4. The weekly review looks at rate-limit hits, challenges, bans and the false-challenge rate (honest finders who met a puzzle). The 60-second sighting must stay possible for honest people.

## B7. Privacy requests
Self-service deletion and export exist in the app; letters and emails are handled with `ptctl privacy …` (OPS-07 §9) so that the cascade and the audit tombstone are the record. Deletion includes the derived data (crops, embeddings). SLA 72 h; breaches alert.

## B8. When something looks wrong
| You see | Do |
|---|---|
| A coordinate in any public screen or export | Treat as an incident: OPS-07 RB-07 — public routes off, then investigate |
| Owners complaining about too many alerts | Check duplicates first, then the threshold for that region |
| Many finders asking "why the puzzle?" | False-challenge rate too high — raise `trust.captcha_below` back down |
| Possible sightings all far away / old | The owner widened radius/days; the score shows why; nothing to fix |
| A model file changed on disk | The worker halts by design (SEC-07 §5.6); restore from the release store |

---

# Part C — Glossary (EN / TH)

| English | ไทย | Meaning |
|---|---|---|
| Lost dog post | ประกาศหมาหาย | An owner's report |
| Sighting | การพบเห็น | A finder's report; no account needed |
| Possible sighting | การพบเห็นที่อาจใช่ | A ranked candidate — never "match" |
| Confirmation rate | อัตราที่ยืนยันว่าใช่ | Share of similar candidates confirmed by owners |
| Confirm / Not my dog | ใช่หมาของฉัน / ไม่ใช่ | The owner's decision |
| Area (cell) | พื้นที่โดยประมาณ | ~5 km square shown publicly instead of a point |
| Share exact location | แชร์ตำแหน่งจริง | Both sides must agree |
| Reunited | ได้กลับบ้านแล้ว | Closes the post |
| Chat | แชท | In-app relay; no phone/email exchanged |
| Report abuse | รายงานปัญหา | Sends a post/photo/chat to a moderator |
| Puzzle (CAPTCHA) | ยืนยันว่าไม่ใช่บอท | Shown only after abuse signals |
| Delete my data | ลบข้อมูลของฉัน | Everything, including derived data, within 72 h |
| Daily alert limit | จำกัดการแจ้งเตือนต่อวัน | 5 per day; the rest in an evening summary |
