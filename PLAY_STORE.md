# نشر Multicam Studio على Google Play

معرّف التطبيق: `com.multicamstudio.multicam_studio` (لا يتغير بعد النشر).

روابط السياسات (GitHub Pages):
- سياسة الخصوصية: https://baraaelh.github.io/multicam-studio1/privacy.html
- شروط الاستخدام: https://baraaelh.github.io/multicam-studio1/terms.html

---

## 1. حساب المطوّر
- سجّل في https://play.google.com/console (رسوم 25$ مرة واحدة).
- الحسابات الشخصية الجديدة: لازم **اختبار مغلق مع 12 مختبِر على الأقل لمدة 14 يوم** قبل طلب النشر للعامة.

## 2. مفتاح التوقيع (مرة واحدة فقط)
على ويندوز، من PowerShell:

```powershell
keytool -genkey -v -keystore $env:USERPROFILE\upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

> إذا ما لقى `keytool`، استخدم المسار الكامل:
> `"C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe"`

بعدها أنشئ الملف `android/key.properties` (ما بينرفع على GitHub):

```properties
storePassword=كلمة_سر_المفتاح
keyPassword=كلمة_سر_المفتاح
keyAlias=upload
storeFile=C:/Users/اسم_المستخدم/upload-keystore.jks
```

⚠️ احتفظ بنسخة احتياطية من `upload-keystore.jks` وكلمة السر بمكان آمن. ضياعهم يعني طلب إعادة تعيين من Google.

## 3. بناء ملف المتجر
قبل كل رفع زِد رقم النسخة في `pubspec.yaml` (مثلاً `1.0.0+1` ← `1.0.1+2`)، ثم:

```bash
flutter build appbundle --release --dart-define=APP_CHECK_PLAY_INTEGRITY=true
```

(أو `bash tool/build_play_release.sh` من Git Bash.)

الملف الناتج: `build/app/outputs/bundle/release/app-release.aab`

## 4. App Check مع Play Integrity
1. Play Console ← التطبيق ← **Test and release › App integrity** ← انسخ **SHA-256** لمفتاح **App signing key**.
2. Firebase Console ← Project settings ← تطبيق Android ← **Add fingerprint** ← الصق البصمة.
3. Firebase Console ← **App Check** ← تطبيق Android ← فعّل **Play Integrity**.
4. Google Cloud Console للمشروع نفسه: فعّل **Play Integrity API**.
5. لا تفعّل الـ Enforcement إلا بعد ما تتأكد من نسخة الاختبار إن الطلبات تظهر "Verified" في صفحة App Check.

## 5. صفحة المتجر (Store listing)
- **الاسم:** Multicam Studio
- **وصف قصير (80 حرف):**
  `Turn Android phones into a synced multi-camera studio. Cut live, get one video.`
- **الوصف الكامل:**

```
Multicam Studio turns a few Android phones into a synced multi-camera studio.

• Up to 8 camera phones and one director phone
• Live preview of every angle over your local Wi-Fi
• Tap a camera to cut live; every phone starts recording at the same instant
• Each phone records in full quality; files move to the director automatically
• One finished video, cut exactly where you switched
• Flexible audio: one camera's mic, the director's mic, or audio that follows the cuts
• No account needed. Your videos never leave your phones.

How it works
1. On the director phone, open Admin Mode and create a session.
2. Share the 6-digit code with the camera phones.
3. Go live, start recording and cut between angles.
4. Stop: the app collects the files and renders your video.

All phones must be on the same Wi-Fi network or hotspot.

Developed by Baraa Alhaddad.
```

- **التصنيف:** Video Players & Editors
- **الأيقونة:** 512×512 PNG
- **صورة الغلاف:** 1024×500 PNG
- **صور الشاشات:** 2 إلى 8 صور للجوال (موجودة من البرزنتيشن).

## 6. Data safety (أمان البيانات)
| السؤال | الإجابة |
|---|---|
| هل يجمع التطبيق أو يشارك بيانات؟ | نعم (يجمع)، لا يشارك |
| هل كل البيانات مشفّرة أثناء النقل؟ | نعم |
| هل يمكن طلب حذف البيانات؟ | نعم (تُحذف عند انتهاء الجلسة) |
| **Device or other IDs** | Collected · App functionality · غير اختياري · لا يُشارك |
| Photos and videos / Audio | **غير مجموعة** (تبقى على الأجهزة وتنتقل بينها مباشرة عبر الشبكة المحلية) |
| Location, Personal info, Contacts, Financial, Messages | لا |

## 7. Foreground service (الكاميرا والمايك بالخلفية)
Play Console ← **App content › Foreground service permissions**:
- الأنواع: `camera`, `microphone`
- **الوصف:**
  `The camera phone keeps recording and streaming video and audio to the director phone while its screen is off or another app is in front. Recording is started and stopped by the user from the director phone and a persistent notification is shown the whole time.`
- **فيديو:** سجّل مقطع قصير (YouTube غير مُدرج) يوضح بدء التسجيل من المخرج وإشعار الكاميرا ظاهر.

## 8. باقي نماذج App content
- **Privacy policy:** رابط سياسة الخصوصية بالأعلى.
- **Ads:** لا يحتوي إعلانات.
- **App access:** كل الميزات متاحة بدون تسجيل دخول.
- **Content rating:** عبّئ الاستبيان (أداة تصوير، بدون محتوى عنيف أو تفاعل بين مستخدمين غرباء).
- **Target audience:** 18+.
- **Government apps / Financial / Health:** لا.

## 9. الترتيب
1. Internal testing (اختياري، للتجربة السريعة).
2. **Closed testing** مع 12 مختبِر لمدة 14 يوم.
3. **Production** بعد الموافقة.
