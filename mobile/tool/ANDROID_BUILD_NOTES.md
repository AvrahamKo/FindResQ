# בניית LifeSearch ל־Android מ־Windows — ממצאים ופתרונות

> מסמך ממוקד לבעיית הבנייה בלבד. ההקשר הרחב של הפרויקט נמצא ב־`HANDOVER.md` בשורש.
> נכתב 2026-08-06.

## המטרה

להריץ את מסך ה־Tactical HUD של המתנדב על מכשיר Android פיזי.
**המסך מעולם לא רץ על חומרה אמיתית** — הוא מכוסה ב־widget tests בלבד. שלושה
דברים לא נבדקו כלל: מחוות **hold-to-SOS** באצבע, **pinch/pan** על המפה, ורכישת
**GPS** אמיתית.

המכשיר: **Xiaomi 2201116TG**, Android 13, `android-arm64`, ADB id
`BMHUPFLBUKRGAACA`.

## שלוש תקלות נפרדות שהתחזו לאחת

הבנייה נכשלה שוב ושוב בהודעות שונות. התברר שמדובר בשלוש בעיות בלתי־תלויות.
כולן **אובחנו ותוקנו**; פירוט למקרה שיחזרו.

### 1. בחירת ה־shell (תוקן)

ל־build hook של `sodium` יש **שתי** דרישות מה־shell, ולא אחת:

1. `make` חייב לעבוד
2. `/c/...` חייב להתפרש כ־`C:\` (סגנון MSYS), כי ה־hook מעביר
   `--prefix=/c/Users/...`

מדידה בפועל על המכונה הזו:

| shell | make | `/c/` | מה קורה |
|---|---|---|---|
| `Git\bin\bash.exe` | ❌ | ✅ | `config.status: Something went wrong bootstrapping makefile fragments` |
| `cygwin64\bin\bash.exe` | ✅ | ❌ | מקמפל aarch64 **מושלם**, ואז מתקין ל־`C:\cygwin64\c\Users\...` → `Code asset ... does not exist as a file` |
| **`Git\usr\bin\bash.exe`** | ✅ | ✅ | **זה הנכון** |

**ההבדל בין שני ה־bash של Git — קריטי:**
`Git\bin\bash.exe` הוא *wrapper* שבונה מחדש את ה־PATH בהפעלה ותמיד נוחת על
`/usr/bin/make` — **לא ניתן לעקיפה מבחוץ** (נבדק אמפירית: הקדמת make תקין
ל־PATH של Windows לא עוזרת, וגם `$MAKE` לא, כי ה־hook מריץ את המחרוזת `make`
מילולית).
`Git\usr\bin\bash.exe` הוא ה־MSYS bash הגולמי — הוא **יורש** את ה־PATH, ולכן
make שנקדים לו מנצח.

⚠️ **טעות שקל לחזור עליה:** לבדוק `make --version` מ־PowerShell. זה בינארי אחר
לגמרי מזה שהבנייה תשתמש בו. חייבים לבדוק **בתוך ה־bash הרלוונטי**, ועם `-c`
(לא `-lc`, כי login shell בונה מחדש את ה־PATH ואינו מייצג את מה שה־hook עושה).

**התיקון:** `mobile/tool/build_android.ps1` — מרכיב PATH דטרמיניסטי לתהליך
הבנייה בלבד, ללא שינוי מערכת קבוע. סדר ה־PATH:
`<NDK prebuilt bin>` (GNU Make 4.3 תקין) → `Git\usr\bin` (bash גולמי) → השאר.
הסקריפט **בודק את שתי הדרישות** על כל מועמד לפני שהוא מתחיל.

`Git\usr\bin` **כן** נמצא ב־PATH בכוונה — אבל אחרי ה־make התקין. זה מה שמונע
מה־make השבור של Git לנצח.

### 2. זיכרון (תוקן)

`android/gradle.properties` הגיע מתבנית Flutter עם
`-Xmx8G -XX:MaxMetaspaceSize=4G` — בקשה של עד **12GB**, על מכונה עם **13.9GB**
פיזיים ו־**2GB פנויים** (Edge ~3GB, ChatGPT 1GB, WSL 850MB, Docker).

ה־JVM לא הצליח להקצות heap ומת. ההודעה שהתקבלה:

```
Gradle build daemon disappeared unexpectedly (it may have been killed or may have crashed)
```

— הודעה שאינה רומזת כלל על זיכרון. **הורד ל־`-Xmx3G -XX:MaxMetaspaceSize=1G`.**

### 3. ABI מיותר וזמן (תוקן)

הבנייה קימפלה גם ARM 32-ביט (נמצא `.so` בארכיטקטורה `ELF 32-bit ARM` במטמון).
כל ABI הוא קרוס־קומפילציה מלאה של libsodium — פי ~3 עבודה. הסקריפט מקבע
`--target-platform android-arm64`.

בנוסף — **הבנייה איטית בהרבה ממה שנראה סביר, וזה תקין**:

| שלב | זמן בפועל |
|---|---|
| `configure` | ~10 דקות |
| `make` (קומפילציה) | ~10 דקות |
| **`make install`** | **~10 דקות** |

`make install` הוא "רק העתקת קבצים" בתיאוריה, אבל הוא מעתיק מאות header files
אחד־אחד, וכל spawn של תהליך תחת MSYS יקר מאוד. בסך הכול **~30 דקות לבנייה
נקייה**. כל timeout קצר מזה ייחתך באמצע וייראה בדיוק כמו כישלון.
**להריץ ברקע, בלי timeout.**

### איך להבדיל בין "איטי" ל"תקוע" — חשוב

הטעות שחזרה כאן פעמיים:

1. **CPU נמוך אינו סימן לתקיעות.** `make install` תחת MSYS הוא I/O־bound —
   CPU כמעט אפס, אבל הוא עובד. גם אין שום פלט ללוג עד שהשלב מסתיים.
2. **המדד הנכון הוא קבצים שמשתנים:**
   ```bash
   D=.dart_tool/hooks_runner/shared/sodium/build/<hash>/libsodium-stable
   find "$D" -type f -newermt '-2 minutes' | wc -l     # >0 = מתקדם
   find "$D/install" -type f | wc -l                    # גדל = make install רץ
   ```
3. ⚠️ **לבדוק את תיקיית ה־hash הפעילה, לא את הראשונה אלפביתית.** יש כמה
   תיקיות מריצות קודמות; ה־hash משתנה עם תצורת ה־compiler/bash. לזהות לפי
   זמן שינוי אחרון או לפי מי שמכילה `.o`. אבחנתי פעם אחת "deadlock" רק כי
   בדקתי תיקייה נטושה.
4. תקיעות אמיתית נראית כך: **אפס קבצים שהשתנו במשך כמה דקות** + אין תהליכי
   `clang`/`make`.

## מצב נכון לסיום ה־session

- ✅ הסקריפט `mobile/tool/build_android.ps1` נכתב ועובד; ה־preflight שלו עובר:
  ```
  make dir : ...\ndk\30.0.14904198\prebuilt\windows-x86_64\bin
  bash     : C:\Program Files\Git\usr\bin\bash.exe
  make     : GNU Make 4.3  (resolved INSIDE that bash)
  /c/ maps : C:\  (MSYS-style)
  ```
- ✅ `android/gradle.properties` הוקטן ל־3GB
- ✅ **הקומפילציה הכבדה כבר במטמון**: 131 קבצי `.o` ו־`libsodium.so` מקושר,
  מאומת כ־`ELF 64-bit LSB shared object, ARM aarch64, for Android 24` (389KB)
  ב־`.dart_tool/hooks_runner/shared/sodium/build/be8478506c/`
- 🔄 **בנייה אחרונה עדיין רצה** כשה־session נגמר — עברה את `configure`, הייתה
  בשלב `make`. יש לבדוק אם הסתיימה.
- ❌ **טרם הותקן APK** מהקוד הנוכחי, וטרם נבדק דבר על המכשיר.

## מה לעשות עכשיו

```powershell
cd C:\Users\avrah\FindResQ\mobile
.\tool\build_android.ps1 -Target install
```

להריץ **ברקע / בלי timeout**. אם `configure` רץ מחדש זה ~10 דק'; ה־`.o`
במטמון אמורים לחסוך את הקומפילציה.

הסקריפט מאמת בעצמו ש־`lib/arm64-v8a/libsodium.so` נכנס ל־APK לפני התקנה — `.so`
חסר לא מפיל את הבנייה אלא את האפליקציה בעלייה, רחוק מהסיבה.

### אם נכשל שוב

1. **`daemon disappeared`** → זיכרון. לסגור Edge/ChatGPT או `wsl --shutdown`.
2. **`bootstrapping makefile fragments`** → נבחר bash עם make שבור. לבדוק את
   פלט ה־preflight.
3. **`Code asset ... does not exist as a file`** → נבחר Cygwin. לוודא
   ש־`Git\usr\bin\bash.exe` נבחר. לנקות גם `C:\cygwin64\c\` אם נוצר.
4. שורות `ld.lld: error: undefined symbol: memset_s` ב־`config.log` הן
   **בדיקות תקינות רגילות של configure** — לא הסיבה לכישלון. לא לרדוף אחריהן.
5. לניקוי מלא: למחוק `.dart_tool/hooks_runner/shared/sodium/build` בלבד
   (לא את כל `.dart_tool`), ולהריץ עם `-CleanNative`.

## אחרי שההתקנה מצליחה — מה לבדוק על המכשיר

רשת: `adb reverse tcp:8000 tcp:8000` (ברירת המחדל באפליקציה היא
`127.0.0.1:8000`). ל־Wi-Fi ללא כבל: `-BaseUrl http://<LAN-IP>:8000`.
הבקאנד חייב לרוץ (`cd backend && uvicorn app.main:app --host 0.0.0.0 --port 8000`).

- התחברות ← הצטרפות לסקטור ← מסך HUD עולה
- סרגל סטטוס: GPS / סוללה / uplink מציגים ערכים אמיתיים
- **hold-to-SOS**: לחיצה קצרה לא מפעילה, החזקה 1.5 שנ' כן
- **מפה**: pinch/pan; גבול הסקטור מצויר
- **`coverage_layer_toggle`**: מעבר בין כיסוי צוותי (`coverage_team`) לשביל
  אישי (`coverage_mine`) — מקומיט `946f4c3`
- **`last_server_sync`** מתעדכן אחרי סנכרון
- הליכה קצרה → נקודות ב־DB:
  ```
  docker exec -i lifesearch-db psql -U lifesearch -d lifesearch -c "SELECT count(*), max(recorded_at) FROM track_points;"
  ```

⚠️ הדגימה מבוססת **מרחק** (10 מ' בטיר הגבוה), לא זמן — עמידה במקום לא מייצרת
נקודות. בסוללה נמוכה הטיר עולה ל־50–100 מ'.

## מגבלות ידועות

- **MIUI חוסם `adb shell input`** (`INJECT_EVENTS`) — אפשר להתקין, להריץ, לצלם
  מסך ולקרוא logcat, **אי אפשר** להקליק מרחוק. מחוות המגע חייבות להתבצע ידנית,
  אלא אם מפעילים *Developer options → USB debugging (Security settings)*.
- **MIUI חוסם `adb install`** כברירת מחדל (`INSTALL_FAILED_USER_RESTRICTED`) —
  צריך *Developer options → Install via USB*. כבר הופעל בעבר, ייתכן שיתאפס.
- **`Git\usr\bin\make.exe` שבור** במכונה הזו (exit 127, לא טוען `msys-2.0.dll`).
  לא תוקן בכוונה — עוקפים אותו. כל כלי אחר שמריץ `make` מתוך Git Bash ייכשל.
- **לא לשנות ל־`sodium_libs`** — discontinued, ותלוי ב־`sodium` עצמו, כלומר
  יוסיף עטיפה מתה מעל אותו build hook.
- **לא לשדרג ל־`sodium` 4.0.4** יחד עם תיקוני סביבה — 4.0.3 היא הגרסה שבנייתה
  הוכחה. שינוי גרסה במקביל מערבב משתנים.
- **הסימולטור** (`/dashboard/sim.html`) מייצר תנועה מרובת־משתמשים אמיתית מול
  ה־pipeline, אבל **אינו תחליף** לקלט מגע אמיתי.
