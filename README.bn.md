# rdlive — প্রজেক্ট ডকুমেন্টেশন (বাংলা)

**rdlive** একটি লাইভ স্ট্রিমিং ও অডিও/ভিডিও সোশ্যাল প্ল্যাটফর্ম। এই ZIP-এ তিনটি অংশ আছে:
Flutter মোবাইল অ্যাপ (ফ্রন্টএন্ড), Go ব্যাকএন্ড API এবং PostgreSQL ডেটাবেস স্কিমা।

---

## ১. ফোল্ডার কাঠামো

```
rdlive/
├── README.bn.md                  ← এই ফাইল (বাংলা গাইড)
├── .gitignore
│
├── frontend_flutter/             ← Flutter মোবাইল অ্যাপ
│   ├── pubspec.yaml              ← প্যাকেজ/ডিপেন্ডেন্সি তালিকা
│   └── lib/
│       ├── main.dart             ← অ্যাপ শুরু + লগইন/হোম গেট
│       ├── config/api_config.dart        ← ব্যাকএন্ডের ঠিকানা, mock চালু/বন্ধ
│       ├── models/live_room.dart         ← লাইভ রুমের মডেল
│       ├── services/auth_service.dart    ← Google/Facebook লগইন
│       ├── services/room_api.dart        ← রুম লিস্ট API (এখন mock ডেটা)
│       ├── theme/app_theme.dart          ← রঙ ও থিম
│       ├── screens/login_screen.dart     ← লগইন স্ক্রিন
│       ├── screens/home_screen.dart      ← হোম স্ক্রিন
│       └── widgets/                      ← ছোট UI অংশ
│           ├── festive_decor.dart        (লণ্ঠন, আর্চ প্যাটার্ন, তারা)
│           ├── home_header.dart          (ট্যাব: Discover/New/Follow, আইকন)
│           ├── hero_banner.dart          (ব্যানার + ক্রাউন ক্যারেক্টার)
│           ├── room_card.dart            (রুম কার্ড, ২-কলাম গ্রিড)
│           ├── rd_bottom_nav.dart        (নিচের নেভ + Go Live বাটন)
│           ├── social_button.dart        (Google/Facebook বাটন)
│           └── net_image.dart            (নেটওয়ার্ক ইমেজ + প্লেসহোল্ডার)
│
├── backend_go/                   ← Go ব্যাকএন্ড (REST API)
│   ├── go.mod
│   ├── .env.example              ← পরিবেশ ভেরিয়েবলের নমুনা
│   ├── README.md                 ← ইংরেজি সংক্ষিপ্ত গাইড
│   ├── cmd/api/main.go           ← সার্ভার চালু করার ফাইল
│   └── internal/
│       ├── config/config.go      ← env থেকে কনফিগ পড়া
│       ├── auth/firebase.go      ← Firebase ID টোকেন যাচাই
│       ├── auth/tokens.go        ← JWT ও refresh টোকেন
│       ├── api/server.go         ← রাউটার ও রুট তালিকা
│       ├── api/middleware.go     ← লগইন চেক, rate limit
│       ├── api/auth.go           ← /v1/auth/social, /v1/auth/refresh, /v1/me
│       ├── api/wallet.go         ← ওয়ালেট ও লেজার (passbook)
│       ├── api/recharge.go       ← রিচার্জ অর্ডার + পেমেন্ট webhook
│       ├── api/gifts.go          ← গিফট লিস্ট ও গিফট পাঠানো
│       ├── payments/             ← পেমেন্ট গেটওয়ে (bKash, Stripe কার্ড)
│       └── realtime/publisher.go ← রুম ইভেন্ট পাঠানোর ইন্টারফেস
│
└── database_sql/
    └── schema.sql                ← সম্পূর্ণ PostgreSQL স্কিমা + সিড ডেটা
```

---

## ২. আগে যা ইনস্টল করা লাগবে

| টুল | ব্যবহার |
|---|---|
| Flutter SDK (Dart ≥ 3.3) | মোবাইল অ্যাপ |
| Go ≥ 1.22 | ব্যাকএন্ড |
| PostgreSQL ≥ 14 | ডেটাবেস |
| Firebase প্রজেক্ট | Google/Facebook লগইন যাচাই |

---

## ৩. চালানোর ধাপ (এই ক্রমে করুন)

### ধাপ ১ — ডেটাবেস তৈরি

```bash
createdb rdlive
psql "postgres://postgres:postgres@localhost:5432/rdlive" -f database_sql/schema.sql
```

এতে সব টেবিল, ফাংশন (`wallet_apply`, `settle_recharge`, `send_gift`, `request_withdrawal`,
`finalize_host_month`) এবং নমুনা ডেটা (লেভেল ১–১০০, গিফট, রিচার্জ প্যাকেজ, টার্গেট টিয়ার) তৈরি হবে।
নমুনা মান (রেট, দাম, টিয়ার) আপনার ব্যবসার নিয়ম অনুযায়ী বদলে নিন।

### ধাপ ২ — Go ব্যাকএন্ড

```bash
cd backend_go
go mod tidy                      # ডিপেন্ডেন্সি নামাবে এবং go.sum তৈরি করবে
cp .env.example .env             # তারপর .env ফাইলে নিজের মান বসান
```

`.env`-এর মান এক্সপোর্ট করে সার্ভার চালান:

```bash
set -a; source .env; set +a
go test ./...                    # টেস্ট চালান
go run ./cmd/api                 # সার্ভার চালু (ডিফল্ট :8080)
```

চালু হয়েছে কিনা দেখতে: `curl http://localhost:8080/healthz`

**প্রয়োজনীয় env ভেরিয়েবল:** `DATABASE_URL`, `JWT_SECRET` (কমপক্ষে ৩২ অক্ষর),
`FIREBASE_PROJECT_ID`, `PUBLIC_BASE_URL`। bKash ও Stripe-এর কী ঐচ্ছিক।

### ধাপ ৩ — Flutter অ্যাপ

এই ZIP-এ শুধু `lib/` ও `pubspec.yaml` আছে। Android/iOS ফোল্ডার নেই, তাই প্রথমবার এটি তৈরি করুন:

```bash
cd frontend_flutter
flutter create --platforms=android,ios --org com.rdlive .
flutter pub get
```

এরপর `pubspec.yaml`-এ `firebase_auth`, `google_sign_in`, `flutter_facebook_auth` ইত্যাদি
ডিপেন্ডেন্সি আছে কিনা একবার দেখে নিন।

**Firebase ও লগইন সেটআপ (অ্যাপ চালানোর আগে আবশ্যক):**
1. Firebase কনসোলে প্রজেক্ট খুলে Authentication-এ **Google** ও **Facebook** চালু করুন।
2. `dart pub global activate flutterfire_cli` তারপর `flutterfire configure` চালান।
3. Android-এ Google লগইনের জন্য নিজের **SHA-1** Firebase-এ যোগ করুন।
4. Facebook ডেভেলপার অ্যাপের App ID ও Client Token Android/iOS কনফিগে বসান
   (`flutter_facebook_auth` প্যাকেজের গাইড অনুসরণ করুন)।

**অ্যাপ চালান:**

```bash
flutter run
```

**ব্যাকএন্ডের সাথে যুক্ত করা:** `frontend_flutter/lib/config/api_config.dart` ফাইলে
`baseUrl` নিজের সার্ভারের ঠিকানা দিন এবং `useMockData` কে `false` করুন।
এখন এটি `true` থাকায় অ্যাপ নমুনা (mock) রুম ডেটা দেখায়।

---

## ৪. মূল API তালিকা

| মেথড | পাথ | কাজ |
|---|---|---|
| POST | `/v1/auth/social` | Firebase টোকেন দিয়ে লগইন/রেজিস্ট্রেশন |
| POST | `/v1/auth/refresh` | টোকেন রিফ্রেশ |
| GET | `/v1/me`, `/v1/wallet`, `/v1/wallet/ledger` | প্রোফাইল, ব্যালেন্স, লেনদেনের ইতিহাস |
| GET | `/v1/recharge/packages` | রিচার্জ প্যাকেজ |
| POST | `/v1/recharge/orders` | রিচার্জ শুরু (পেমেন্ট লিংক ফেরত দেয়) |
| GET | `/v1/recharge/orders/{id}` | অর্ডারের অবস্থা |
| ANY | `/webhooks/{provider}` | পেমেন্ট গেটওয়ের কলব্যাক |
| GET | `/v1/gifts` | গিফট ক্যাটালগ |
| POST | `/v1/gifts/send` | গিফট পাঠানো (`Idempotency-Key` হেডার আবশ্যক) |

---

## ৫. নিরাপত্তার মূল নিয়ম

- রিচার্জের অ্যামাউন্ট ও কয়েন সবসময় ডেটাবেসের প্যাকেজ থেকে আসে, ক্লায়েন্ট থেকে নয়।
- webhook-এর প্রোভাইডার, অ্যামাউন্ট ও কারেন্সি অর্ডারের সাথে না মিললে কয়েন যোগ হয় না।
- ব্যালেন্স শুধু `wallet_apply()` ফাংশনের মাধ্যমে বদলায়; লেজার শুধু যোগ করা যায়, বদলানো বা মোছা যায় না।
- একই রিচার্জ বা গিফট রিকোয়েস্ট দুইবার এলেও একবারই কার্যকর হয়।
- ইউজার-থেকে-ইউজারে সরাসরি কয়েন ট্রান্সফারের কোনো ফাংশন নেই।
- ব্যান করা IP/ডিভাইস লগইনেই আটকে যায়; একটি ডিভাইসে সর্বোচ্চ ৩টি অ্যাকাউন্ট।

---

## ৬. এখনো বাকি / সীমাবদ্ধতা

- **Nagad ও Rocket:** রুট আছে কিন্তু এখনো `501` ফেরত দেয়। Nagad-এর জন্য মার্চেন্ট RSA কী লাগবে,
  Rocket সাধারণত SSLCommerz/aamarPay/ShurjoPay-এর মতো অ্যাগ্রিগেটরের মাধ্যমে যুক্ত করতে হয়।
- **bKash:** tokenized checkout ফ্লো অনুযায়ী লেখা; আপনার bKash API ভার্সনের ফিল্ডের নাম মিলিয়ে নিন।
- PayPal, উইথড্রল API এন্ডপয়েন্ট এবং pending bKash অর্ডার মেলানোর (reconcile) জব এখনো নেই।
- Flutter অ্যাপ এখনো লগইনের সময় `device_id` পাঠায় না; ডিভাইস ব্যান/লিমিট কাজ করাতে এটি যোগ করতে হবে
  (তারপর `REQUIRE_DEVICE_ID=true` করা যাবে)।
- রুম, সিট, PK ব্যাটেল, মডারেশন, Agora ইন্টিগ্রেশন — পরবর্তী ধাপ।

## ৭. পরীক্ষার অবস্থা (সততার সাথে)

- ✅ `database_sql/schema.sql` PostgreSQL 16-এ চালিয়ে দেখা হয়েছে; রিচার্জ, গিফট, উইথড্রল, মাসিক টার্গেট ফাংশন ও লেজার-অপরিবর্তনীয়তা পরীক্ষিত।
- ✅ Go `payments` প্যাকেজের টেস্ট পাস করেছে (bKash/Stripe পার্সিং, সিগনেচার যাচাই)।
- ⚠️ Go-র বাকি অংশ (`api`, `auth`, `main`) আমার পরিবেশে কম্পাইল করে চালানো যায়নি (মডিউল ডাউনলোড ব্লক ছিল)।
  প্রথমে `go mod tidy && go test ./...` চালিয়ে দেখুন; কোনো এরর এলে জানান।
- ⚠️ Flutter কোড `flutter analyze` বা ডিভাইসে চালিয়ে দেখা হয়নি।

---

## ৮. রুম মডিউল (সিট, PK ব্যাটেল, মডারেশন) — লোকাল/মক ডেটা

`frontend_flutter/lib/`-এ নতুন ফাইলগুলো (আগের কোনো স্ক্রিন ভাঙা হয়নি):

| ফাইল | কাজ |
|---|---|
| `models/room_models.dart` | ইউজার, সিট, সিট-রিকোয়েস্ট, গিফট মডেল (শুধু Dart) |
| `models/pk_models.dart` | PK মডেল ও `formatScore()` |
| `services/room_controller.dart` | সিটের সব লজিক: জয়েন/লিভ, মাইক/ক্যামেরা, লক/আনলক, মিউট, কিক, ব্যান |
| `services/pk_controller.dart` | PK টাইমার (৫ মিনিট), স্কোর, বিজয়ী নির্ধারণ |
| `widgets/seat_grid.dart`, `seat_tile.dart` | ৪ ও ৮ সিটের রেসপনসিভ গ্রিড (অডিও/ভিডিও মোড) |
| `widgets/seat_action_sheet.dart` | সিটে ট্যাপ করলে বটম শিট: প্রোফাইল, গিফট, মিউট, রিমুভ |
| `widgets/room_control_panel.dart` | হোস্ট/মডারেটর প্যানেল: রিকোয়েস্ট, People (মিউট/কিক/ব্যান), Banned |
| `widgets/pk_battle_overlay.dart` | স্প্লিট-স্ক্রিন PK, অ্যানিমেটেড স্কোর বার, কাউন্টডাউন, বিজয়ী ওভারলে |
| `widgets/avatar_circle.dart`, `sheet_frame.dart` | ছোট শেয়ার্ড UI অংশ |
| `screens/room_screen.dart` | সব মডিউল জোড়া লাগানো রুম স্ক্রিন |
| `test/room_logic_test.dart` | কন্ট্রোলারের ইউনিট টেস্ট |

**একমাত্র বদল পুরনো ফাইলে:** `screens/home_screen.dart`-এ `_openRoom()` এখন `RoomScreen` খোলে
(একটি import ও ৩ লাইন)।

**ডেমো করার উপায়:** হোম থেকে যেকোনো রুম কার্ডে ট্যাপ করুন। রুম স্ক্রিনের উপরের ডানের `⋮` মেনু থেকে
Audio/Video, ৪/৮ সিট, "Act as Audience/Moderator/Host" এবং "Toggle PK battle" বদলাতে পারবেন।
Host হিসেবে নিচের বারের ঢাল-আইকন (Room controls) দিয়ে প্যানেল খুলুন।

**টেস্ট চালাতে:** `flutter test`

**ব্যাকএন্ডের সাথে যুক্ত করার জায়গা:** `RoomController`-এর প্রতিটি মেথড (`requestToJoin`, `approveRequest`,
`kickUser`, `banUser` ইত্যাদি) পরে API/রিয়েলটাইম কলে বদলাবে; PK-তে আসল গিফট ইভেন্ট এলে `PkController.addScore()` কল করুন
(`simulateGifts: false` দিন); ভিডিও সিটে Agora ভিউ বসাতে `SeatGrid(videoBuilder: ...)` ব্যবহার করুন।

**সীমাবদ্ধতা:** এই মডিউল `flutter analyze`/ডিভাইসে চালিয়ে দেখা হয়নি (আমার পরিবেশে Flutter SDK ছিল না)।
প্রথমে `flutter analyze && flutter test` চালিয়ে যা এরর আসে জানান।

---

## ৯. রুম / সিট / PK / মডারেশন — ডাটাবেস (`database_sql/002_rooms_pk_moderation.sql`)

**চালানোর ক্রম:** আগে `schema.sql`, তারপর এটি (একই ডাটাবেসে):

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f database_sql/schema.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f database_sql/002_rooms_pk_moderation.sql
```

এটি পুরনো `live_rooms` টেবিলকে বাড়ায় (নতুন করে বানায় না) এবং যোগ করে:

| টেবিল | কাজ | Flutter-এর সাথে মিল |
|---|---|---|
| `room_members` | রুমে কে আছে, role (audience/moderator/host), `is_muted` | `RoomUser` |
| `room_seats` | সিট ০ = হোস্ট; empty/occupied/locked; mic/camera | `Seat` |
| `seat_requests` | pending/approved/rejected/cancelled | `SeatRequest` |
| `room_bans` | হোস্ট-ভিত্তিক ব্যান (পরের রুমেও কার্যকর) | `banned` তালিকা |
| `host_moderators` | হোস্টের নিযুক্ত মডারেটর (পরের রুমেও মডারেটর) | `RoomRole.moderator` |
| `room_moderation_log` | সব স্টাফ অ্যাকশনের অডিট (বদলানো/মোছা যায় না) | — |
| `pk_battles` | Host A (লাল) বনাম B (নীল), স্কোর, ৩০০ সেকেন্ড, winner/draw | `PkController` |
| `pk_gift_scores` | PK-তে গোনা প্রতিটি গিফট (একবারই গোনা হয়) | `PkGiftEvent` |

**গুরুত্বপূর্ণ নিয়ম (ডাটাবেসই জোর করে মানায়, Go-তে ভুল হলেও):**
- সিট ০ (হোস্ট) লক বা ত্যাগ করা যায় না; লক করতে সিট খালি থাকতে হবে।
- kick / ban / mute শুধু স্টাফ করতে পারে, এবং শুধু নিজের চেয়ে নিচু role-এর ওপর; নিজের ওপর নয়।
- mute থাকা ইউজার mic চালু করতে পারে না; রুম ছেড়ে আবার ঢুকলেও mute থেকে যায়।
- ব্যান হলে ওই হোস্টের যেকোনো রুমে ঢোকা যায় না, `room_unban_user` পর্যন্ত।
- প্রতি হোস্টের একসাথে একটাই লাইভ রুম এবং একটাই চলমান PK।
- PK-র স্কোর নিজে নিজেই বাড়ে: `gift_transactions`-এ ট্রিগার আছে, তাই `send_gift()` বদলাতে হয়নি।
  PK `running` না থাকলে গিফট গোনা হয় না; একই গিফট রিপ্লে হলে দুবার গোনা হয় না।
- PK শেষ করতে Go থেকে প্রতি ২–৫ সেকেন্ডে `select pk_finish_due();` চালান (সময় না ফুরালে শেষ করে না)।

**রিয়েলটাইম:** প্রতিটি পরিবর্তনে `pg_notify('room_events', ...)` যায়। Go-তে `LISTEN room_events` করে
`realtime.Publisher`-এর মাধ্যমে ক্লায়েন্টকে পাঠান। **রিড মডেল (ভিউ):** `v_live_rooms_feed`, `v_room_seats`,
`v_room_seat_requests`, `v_room_members`, `v_room_banned`, `v_pk_battle_state`।

ফাংশন → এন্ডপয়েন্ট ম্যাপিং এবং এরর → HTTP স্ট্যাটাস তালিকা SQL ফাইলের একদম শেষে কমেন্টে আছে।

**পরীক্ষার অবস্থা:** PostgreSQL 16-এ `schema.sql`-এর ওপর এই মাইগ্রেশন চালিয়ে ~৬০টি চেক পাস করেছে
(সিট ফ্লো, লক নিয়ম, র‍্যাংক, mute/kick/ban, লেআউট ছোট করা, PK স্কোর/ড্র/রিম্যাচ, রুম শেষ হলে PK বাতিল)।
একটি বাগ পেয়ে ঠিক করা হয়েছে (`room_mute_user`-এর enum cast)। **এখনো বাকি:** Go-তে এই ফাংশনগুলোর HTTP হ্যান্ডলার
ও `LISTEN` ওয়ার্কার লেখা হয়নি, এবং "Follow" ট্যাবের জন্য `follows` টেবিল এই মাইগ্রেশনে নেই।

---

## ১০. কয়েন বিতরণ ও রিসেলার সিস্টেম (`database_sql/003_coin_distribution.sql` + Go API)

**ক্রম:** Master (Super Admin) → Coin Seller (৬–৭ জন বা বেশি) → Agency Owner / Host / User → গিফট → Host-এর ডায়মন্ড।

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f database_sql/schema.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f database_sql/002_rooms_pk_moderation.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f database_sql/003_coin_distribution.sql
# প্রথম Super Admin একবার হাতে বানাতে হবে (এর জন্য ইচ্ছাকৃতভাবে কোনো API নেই):
psql "$DATABASE_URL" -c "update users set role='super_admin' where public_id = <আপনার ৮-সংখ্যার ID>;"
```

**নতুন `user_wallets` / `coin_transactions` টেবিল বানাইনি — কেন?** আগের `wallets` (ব্যালেন্স, `coins >= 0` CHECK) ও `wallet_ledger`
(অপরিবর্তনীয় খতিয়ান) ঠিক এই কাজই করে। দ্বিতীয় একটি ব্যালেন্স-টেবিল রাখলে দুই জায়গার হিসাব মিলিয়ে রাখার ঝামেলা ও ভুলের ঝুঁকি তৈরি হতো।
তাই ওই নামে দুটি **ভিউ** দিয়েছি (`user_wallets`, `coin_transactions`), যেখানে প্রতিটি কয়েন-মুভমেন্টের সাথে কাউন্টারপার্টি, দাম (৳) ও পেমেন্ট রেফ আছে।
নতুন আসল টেবিল: `coin_sellers`, `coin_transfers` (mint / seller_sale / reclaim-এর ব্যবসায়িক রেকর্ড), `coin_policy`, `coin_admin_log`।

**ডাবল-স্পেন্ড / গরমিল ঠেকানোর ব্যবস্থা (সব ডাটাবেসে, Go ভুল করলেও কাজ করে):**
- সব কয়েন নড়াচড়া `wallet_apply()` দিয়ে: রো-লক + ব্যালেন্স কখনো ঋণাত্মক হতে পারে না।
- দুই ওয়ালেট সবসময় `user_id`-এর ক্রমে লক হয় (A→B ও B→A একসাথে হলেও ডেডলক নেই)।
- একই `Idempotency-Key` আবার পাঠালে একই ট্রান্সফার ফেরত আসে, দ্বিতীয়বার কয়েন যায় না; একই key দিয়ে ভিন্ন অনুরোধ পাঠালে `409`।
- সেলারের দৈনিক লিমিট ও প্রতি-ট্রান্সফার লিমিট; একই bKash/Nagad TrxID দিয়ে দুবার বিক্রি করা যায় না।
- সেলার শুধু `user / host / agency_owner`-কে পাঠাতে পারে (সেলার→সেলার, অ্যাডমিন বা নিজেকে নয়) — আগের "P2P ট্রান্সফার নেই" নিয়ম বজায় আছে।
- Master-এর দৈনিক mint সীমা (`coin_policy`): অ্যাডমিন অ্যাকাউন্ট হ্যাক হলেও অসীম কয়েন বানানো যাবে না।
- `coin_transfers` ও `wallet_ledger` কখনো এডিট/ডিলিট করা যায় না; ভুল হলে নতুন `reclaim` বা বিক্রি দিয়ে শোধরাতে হয়।
- অডিট: `audit_wallet_integrity()`, `audit_transfers()`, `coin_supply_report()` (ফলাফল ফাঁকা = সব ঠিক)।

**গিফট (`send_gift`) — একই সিগনেচার, শক্ত করা হয়েছে:** ওয়ালেট ক্রমে লক; রুম-গিফটে প্রেরক ও প্রাপক দুজনকেই রুমে থাকতে হবে
(কিক/ব্যান হওয়া ইউজার পাঠাতে পারে না); `host_daily_stats.gift_count` এখন বাড়ে; PK স্কোর ট্রিগার অপরিবর্তিত ও একই ট্রানজ্যাকশনে চলে;
কমিট হলে `room_events`-এ `gift` ইভেন্ট যায় (প্রাপকের আজকের মোট ডায়মন্ডসহ) — তাই Go থেকে আর আলাদা করে publish করা হয় না (ডুপ্লিকেট এড়াতে সরানো হয়েছে)।

### Go এন্ডপয়েন্ট (সব `Authorization: Bearer <token>`; টাকার POST-এ `Idempotency-Key` বাধ্যতামূলক)
রোল **প্রতিটি রিকোয়েস্টে ডাটাবেস থেকে** যাচাই হয় (টোকেনের role দাবি উপেক্ষা করা হয়), তাই সেলার সাসপেন্ড/ডিমোট করলে সাথে সাথে কার্যকর।

| রোল | মেথড ও পাথ | কাজ |
|---|---|---|
| super_admin | `POST /v1/admin/sellers` | ইউজারকে সেলার বানানো (`public_id`, `code`, লিমিট) |
| super_admin | `GET /v1/admin/sellers` · `PATCH /v1/admin/sellers/{id}` | সেলার তালিকা/ব্যালেন্স · সাসপেন্ড/লিমিট বদল |
| super_admin | `POST /v1/admin/coins/mint` | Master → Seller কয়েন তৈরি |
| super_admin | `POST /v1/admin/coins/reclaim` | যেকোনো ওয়ালেট থেকে কয়েন ফেরত/বার্ন (কারণ বাধ্যতামূলক) |
| super_admin | `GET /v1/admin/coins/transfers` · `/coins/audit` · `/wallets/{publicID}` | ইতিহাস · অডিট · ব্যালেন্স চেক |
| coin_seller | `GET /v1/seller/me` | নিজের ব্যালেন্স, আজকের বিক্রি, বাকি লিমিট |
| coin_seller | `GET /v1/seller/lookup?public_id=` | পাঠানোর আগে প্রাপককে চিনে নেওয়া (ব্যালেন্স দেখায় না) |
| coin_seller | `POST /v1/seller/transfers` | Agency/Host/User-কে কয়েন বিক্রি (`to_public_id`, `amount`, `price_bdt`, `payment_method`, `payment_ref`) |
| coin_seller | `GET /v1/seller/transfers` | পাওয়া ও বিক্রির ইতিহাস |
| host | `GET /v1/host/earnings/today` | আজকের ডায়মন্ড ও গিফট সংখ্যা |
| যেকোনো লগইন | `GET /v1/wallet` · `/v1/wallet/ledger` | নিজের ব্যালেন্স ও পাসবুক (আগের মতো) |

**ওয়েব পোর্টাল (ব্রাউজার) থেকে কল করতে** `.env`-এ `PORTAL_ORIGINS=https://admin.example.com,https://seller.example.com` দিন
(কমা দিয়ে, `*` নয়)। ফাঁকা থাকলে ব্রাউজারের ক্রস-অরিজিন কল বন্ধ থাকে। মোবাইল অ্যাপে কোনো প্রভাব নেই।

**ফাইল:** `backend_go/internal/api/{portal.go, portal_admin.go, portal_seller.go}` (হ্যান্ডলার), `internal/coinx/` (ভ্যালিডেশন ও ত্রুটি-ম্যাপিং; `go test ./internal/coinx`)।

**পরীক্ষার অবস্থা (সততার সাথে):**
- SQL: PostgreSQL 16-এ `schema.sql` → `002` → `003` চালিয়ে ৫৫টি কয়েন-চেক + আগের রুম/PK রিগ্রেশন পাস। সমান্তরাল পরীক্ষা: একই ফ্লোট দুবার খরচ করার চেষ্টায় ঠিক একটি সফল;
  একই key একসাথে দুবার → একটাই ট্রান্সফার; ২ ইউজারের মধ্যে ৩০০টি উল্টো-দিকের গিফটে ডেডলক শূন্য; কনকারেন্সির পরেও অডিট পরিষ্কার।
- Go: `coinx` ইউনিট টেস্ট পাস। হ্যান্ডলারগুলো আসল pgx/chi দিয়ে **কম্পাইল ও চালানো যায়নি** (আমার পরিবেশে Go মডিউল ডাউনলোড বন্ধ);
  আমি শুধু সমতুল্য স্টাব লাইব্রেরির বিপরীতে টাইপ-চেক ও `go vet` করেছি, এবং হ্যান্ডলারের ১৮টি SQL স্ট্রিং PG16-এ আলাদাভাবে যাচাই করেছি।
  তাই আপনার মেশিনে `go mod tidy && go build ./... && go test ./...` চালিয়ে যা এরর আসে জানান।
- **এখনো বাকি / সুপারিশ:** পোর্টালের ফ্রন্টএন্ড (HTML/React) বানানো হয়নি; Master ও সেলার অ্যাকাউন্টে 2FA / IP allowlist বসান (এখন শুধু সোশ্যাল লগইন);
  অ্যাডমিন-অ্যাকশনে দুজনের অনুমোদন (maker-checker) চাইলে পরে যোগ করা যাবে।


## ১১. রিয়েল-টাইম ওয়ার্কার, PK টিকার, ফলো ও ১-অন-১ চ্যাট (`004`, `005` + Go)

**মাইগ্রেশনের ক্রম:** `schema.sql → 002 → 003 → 004_follows_chat.sql → 005_media_cleanup.sql` (প্রতিটি `psql -v ON_ERROR_STOP=1 -f ...`)।

### ১১.১ রিয়েল-টাইম (`GET /v1/ws`)
- ডাটাবেস ফাংশনগুলো `pg_notify('room_events', …)` ও `pg_notify('chat_events', …)` ছাড়ে। Go সার্ভার একটি `LISTEN` কানেকশন রাখে (`internal/pgnotify` + `internal/realtime`), সংযোগ কেটে গেলে exponential backoff-এ আবার যুক্ত হয় এবং সবাইকে `resync` পাঠায় (ক্লায়েন্ট তখন REST থেকে স্টেট আবার আনবে)।
- চ্যাটের notify-এ শুধু আইডি থাকে (NOTIFY সীমা ৮০০০ বাইট); পুরো মেসেজ Go ডাটাবেস থেকে লোড করে পাঠায়।
- প্রোটোকল: প্রথম ফ্রেম ১০ সেকেন্ডের মধ্যে `{"op":"auth","token":"<Firebase/JWT>"}` (টোকেন URL-এ নয়)। এরপর `subscribe_room` (শুধু সক্রিয় সদস্য, সর্বোচ্চ ৩ রুম), `unsubscribe_room`, `typing`, `ping`।
  সার্ভার পাঠায়: `ready, ack, error, room_event, chat_message, chat_read, typing, pong, resync`।
- সীমা: ইউজারপ্রতি ৫ সকেট, ধীর ক্লায়েন্ট (১২৮ মেসেজ কিউ ভরলে) বাদ, ৭৫ সেকেন্ড নীরব থাকলে বন্ধ, ৫ মিনিট পরপর অ্যাকাউন্ট ব্যান চেক।
- কিক/ব্যান হলে ওই ইউজার ওই রুমের ইভেন্ট আর পায় না।

### ১১.২ PK টিকার
`worker.RunPKTicker` প্রতি `PK_TICK_SECONDS` (ডিফল্ট ৩, ২–৫ এর মধ্যে বাধ্য) সেকেন্ডে `pk_finish_due()` চালায়; একাধিক সার্ভার চললেও `pg_try_advisory_xact_lock(7001)` দিয়ে একবারই চলে।

### ১১.৩ ফলো / ব্লক
`POST|DELETE /v1/users/{publicID}/follow`, `POST|DELETE /v1/users/{publicID}/block`, `GET /v1/me/following`, `GET /v1/me/followers`।
হোম "Follow" ট্যাব: `GET /v1/rooms?tab=follow` (লাইভ রুম ∩ আপনি যাদের ফলো করেন)। `follow_stats` ট্রিগার দিয়ে আপডেট হয়।

### ১১.৪ চ্যাট ও ছবি
| এন্ডপয়েন্ট | কাজ |
|---|---|
| `POST /v1/chat/conversations` | যেকোনো ইউজারের সাথে কনভারসেশন খোলা/পাওয়া (ব্লক থাকলে নিষেধ) |
| `GET /v1/chat/conversations` | ইনবক্স (শেষ মেসেজ, unread, mute) |
| `GET /v1/chat/conversations/{id}/messages?before_id=&limit=` | ইতিহাস (keyset পেজিনেশন); `after_id=` অফলাইন ক্যাচ-আপের জন্য |
| `POST /v1/chat/conversations/{id}/messages` | টেক্সট/ছবি পাঠানো; `client_msg_id` দিয়ে ডুপ্লিকেট রোধ |
| `POST /v1/chat/conversations/{id}/read` | read receipt |
| `GET /v1/chat/unread` | মোট unread |

**ছবি পাঠানোর ধাপ:** (১) `POST /v1/chat/media` → `media_id` ও আপলোড URL; (২) লোকাল মোডে `PUT /v1/media/{id}/content`, S3 মোডে প্রি-সাইনড PUT এবং তারপর `POST /v1/chat/media/{id}/complete`; (৩) মেসেজ পাঠানোর সময় `kind:"image"` ও `media_id`। ছবি দেখতে `GET /v1/media/{id}` (শুধু কনভারসেশনের দুজন)।
ডাটাবেসে শুধু রেফারেন্স (`media_assets`) থাকে, ফাইল স্টোরেজে। ২৪ ঘণ্টায় অব্যবহৃত আপলোড প্রতি ঘণ্টায় মুছে যায় (`005`)। রেট-লিমিট: ৩০ মেসেজ/মিনিট, ৩০ আপলোড/ঘণ্টা।
`.env`: `MEDIA_DIR`, `MEDIA_MAX_BYTES`, `S3_*`, `PK_TICK_SECONDS`।

### ১১.৫ আজ রাতে টেস্ট করতে
```bash
cd backend_go && go mod tidy && go build ./... && go test ./...
go run ./cmd/devtoken -h        # ডেভ টোকেন
node tools/ws_client.mjs        # দুই ইউজারের WS চ্যাট/রুম ইভেন্ট দেখতে
```

### ১১.৬ পরীক্ষার অবস্থা (সততার সাথে)
- SQL (PG16): রুম/কয়েন রিগ্রেশন পাস; ফলো/চ্যাট/মিডিয়া ৭৭টি চেক; ক্লিনআপ ১০টি; সমান্তরাল সেন্ড-এ ডেডলক/ডুপ্লিকেট শূন্য।
- Go stdlib-ভিত্তিক প্যাকেজ (`ws, media, realtime, worker, roomx, coinx`) `-race` সহ পাস। **এন্ড-টু-এন্ড:** আসল PG16-এ SQL ফাংশন → `pg_notify` → ডিসপ্যাচার → হাব → ক্লায়েন্ট (রুম ইভেন্ট, চ্যাট, read receipt, কিক, লিসেনার কেটে গিয়ে রিকানেক্ট + `resync`) পাস (`go test -tags pgintegration`, `RD_PSQL_ARGS` লাগে)।
- **যাচাই হয়নি:** আসল pgx/chi/jwt দিয়ে কম্পাইল (আমার পরিবেশে মডিউল ডাউনলোড বন্ধ — স্টাবের বিপরীতে টাইপ-চেক ও vet করেছি); পুরো API-র আসল HTTP রান। তাই আপনার মেশিনে প্রথমে `go build ./...` চালান।
- **সীমাবদ্ধতা:** PK শুরুতে প্রতিপক্ষের accept ধাপ নেই; রুম পাসওয়ার্ডে শুধু IP রেট-লিমিট; S3 প্রি-সাইনড PUT-এ সাইজ জোর করা যায় না (বাকেট লাইফসাইকেল দিন); EXIF ক্লায়েন্টে মুছুন; লোকাল মোডে ছবির URL-এ Authorization হেডার লাগে; Flutter-এর চ্যাট/WS UI এখনো বানানো হয়নি; পোর্টাল অ্যাকাউন্টে 2FA/IP allowlist সুপারিশ।


## ১২. পারমিশন সিস্টেম (Flutter: ক্যামেরা, মাইক্রোফোন, ছবি/মিডিয়া, নোটিফিকেশন)

**আগে পপ-আপ না আসার কারণ:** প্রজেক্টে `android/` ও `ios/` ফোল্ডারই ছিল না, `permission_handler` প্যাকেজ ছিল না, আর কোথাও ম্যানিফেস্ট/Info.plist ঘোষণা ছিল না।
iOS-এ `Podfile`-এ `PERMISSION_*=1` ফ্ল্যাগ না থাকলে প্যাকেজ কোনো পপ-আপ ছাড়াই সবসময় "denied" দেয় — এটাও সাধারণ কারণ।

**ফাইল:** `frontend_flutter/lib/permissions/`
- `permission_service.dart` — একমাত্র প্রবেশপথ; একসাথে একটাই সিস্টেম ডায়ালগ (কিউ করা), Android 13+ এ `READ_MEDIA_IMAGES`, নিচের ভার্সনে `READ_EXTERNAL_STORAGE`।
- `permission_intro_screen.dart` + `permission_bootstrap.dart` — প্রথমবার অ্যাপ খুললে ব্যাখ্যা-স্ক্রিন, তারপর একে একে আসল পপ-আপ (নোটিফিকেশন → ক্যামেরা → মাইক → ছবি)। একবারই দেখায়।
- `permission_prompts.dart` — ফিচারের আগে ব্যবহারের জন্য: `PermissionPrompts.forLive(context)` (ক্যামেরা+মাইক), `forVoice`, `forChatImage`। "আর জিজ্ঞেস করবেন না" হলে **Open Settings** ডায়ালগ দেখায়।
- `home_screen.dart`: Go Live চাপলে ক্যামেরা+মাইক চায়; রুমে ঢুকলে ব্যাকগ্রাউন্ডে মাইক চায় (ঢোকা আটকায় না)। `main.dart` অ্যাপকে `PermissionBootstrap` দিয়ে মুড়েছে।

**সেটআপ (একবার):**
```bash
cd frontend_flutter
flutter create --org com.rdlive --project-name rdlive --platforms android,ios .   # android/ ios/ বানায়
python3 tool/apply_platform_config.py    # AndroidManifest, Info.plist, Podfile প্যাচ করে (বারবার চালালেও নিরাপদ)
flutter pub get && cd ios && pod install && cd ..
flutter run                               # আসল ডিভাইসে
```
`platform_config/` ফোল্ডারে তিনটি স্নিপেট আছে (হাতে বসাতে চাইলে)। Android `minSdk` ≥ 23, `compileSdk` ≥ 34 রাখুন; iOS ডিপ্লয়মেন্ট ≥ 13।

**টেস্টের টিপস:** পপ-আপ আবার দেখতে অ্যাপ আনইনস্টল করে ইনস্টল দিন (iOS-এ একবার deny করলে সিস্টেম আর পপ-আপ দেখায় না, শুধু Settings)। Android-এ দুইবার deny করলে একইভাবে ব্লক।

**পরীক্ষার অবস্থা (সততার সাথে):** আমার পরিবেশে Flutter SDK নেই, তাই Dart কোড **কম্পাইল/চালানো হয়নি** এবং ডিভাইসে পপ-আপ দেখা হয়নি।
যা যাচাই হয়েছে: প্যাচ স্ক্রিপ্ট (নমুনা ম্যানিফেস্ট/plist/Podfile-এ প্রয়োগ, দ্বিতীয়বার চালালে অপরিবর্তিত, XML বৈধ)। `test/permission_service_test.dart` লেখা আছে (`flutter test`), কিন্তু চালানো হয়নি।
প্যাকেজ ভার্সন (`permission_handler ^11.3.1`, `device_info_plus ^10.1.2`, `shared_preferences ^2.3.2`) আপনার Flutter ভার্সনের সাথে না মিললে `flutter pub upgrade` চালান।
