# مركز الحياة للمساج — قائمة إصدار الإنتاج

## تم تجهيز المشروع
- Flutter package name: `life_massage`
- Android organization: `com.life.massage`
- App version: `1.0.0+10`
- Android host project is generated reproducibly by CI with `flutter create`.
- CI runs dependency resolution, static analysis, tests, APK build, and AAB build.

## قبل النشر إلى Google Play
1. استبدال أيقونة التطبيق الافتراضية بأيقونة المركز.
2. مراجعة اسم التطبيق والوصف ولقطات الشاشة.
3. إعداد توقيع Android release بمفتاح خاص محفوظ خارج المستودع.
4. إضافة SHA-1/SHA-256 الخاصة بتوقيع التطبيق عند ربط Google services.
5. مراجعة سياسة الخصوصية وإكمال بيانات الجهة المالكة.
6. اختبار APK على أجهزة Android فعلية بمقاسات وإصدارات مختلفة.
7. اختبار الاستعادة من نسخة احتياطية على جهاز منفصل.
8. اختبار الحجوزات المتعارضة والدفع والعملة ونقاط الولاء والصلاحيات.
9. اختبار التطبيق بدون إنترنت ثم بعد عودة الاتصال.
10. عدم رفع أي مفاتيح سرية أو كلمات مرور إلى Git.

## حدود هذه المرحلة
لا يتم الادعاء بأن APK/AAB جاهز ومختبر محليًا؛ بيئة العمل الحالية لا تحتوي على Flutter SDK. ملف GitHub Actions يقوم بالتحقق والبناء عند تشغيله في بيئة CI.
