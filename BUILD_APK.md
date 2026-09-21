# بناء APK / AAB

## محليًا
1. ثبّت Flutter SDK وAndroid Studio + Android SDK.
2. افتح المشروع في Android Studio أو VS Code.
3. نفّذ `flutter pub get`.
4. نفّذ `flutter analyze` ثم `flutter test`.
5. للتجربة: `flutter run`.
6. APK: `flutter build apk --release`.
7. Google Play يفضّل AAB: `flutter build appbundle --release`.

## GitHub Actions
يوجد workflow في `.github/workflows/android.yml` لبناء APK عند push. يجب تشغيله على مستودع GitHub يحتوي هذا المشروع.


## المرحلة الثامنة
- حماية أساسية لتسجيل الدخول والنسخ الاحتياطي والاستعادة مع فحص SHA-256.
