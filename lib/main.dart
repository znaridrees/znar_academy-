import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kReleaseMode, kDebugMode;
import 'package:flutter/services.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'localization/app_localizations.dart';
import 'helpers/language_helper.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'firebase_options.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:screen_protector/screen_protector.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:video_player/video_player.dart';


final ValueNotifier<Locale> localeNotifier =
    ValueNotifier(const Locale('ku'));

/// دۆخی ڕووکار (Light/Dark/System). بەردەوام دەمێنێتەوە لە
/// SharedPreferences و لە Settings دەگۆڕدرێت.
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier(ThemeMode.system);

Future<void> loadSavedThemeMode() async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString('theme_mode');
  switch (saved) {
    case 'light':
      themeModeNotifier.value = ThemeMode.light;
      break;
    case 'dark':
      themeModeNotifier.value = ThemeMode.dark;
      break;
    default:
      themeModeNotifier.value = ThemeMode.system;
  }
}

Future<void> setThemeMode(ThemeMode mode) async {
  themeModeNotifier.value = mode;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('theme_mode', mode.name);
}

/// نرخێک بە دیناری عێراقی پیشان دەدات، بۆ نموونە: 15,000 د.ع
/// (هەموو نرخەکانی ئەپەکە بە IQD ـن، چونکە FIB تەنها IQD
/// پشتگیری دەکات).
String formatIQD(num amount) {
  final digits = amount.round().toString();
  final buffer = StringBuffer();

  for (int i = 0; i < digits.length; i++) {
    if (i != 0 && (digits.length - i) % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(digits[i]);
  }

  return '$buffer د.ع';
}

// ============================================================
// PROTECTED OFFLINE PDF CACHE (Encrypted، ناو ئەپ تەنها)
// ============================================================
// ⚠️ تێبینی گرنگ: ئەم شێوازە کلیلێکی نهێنی بەکاردێنێت کە لەناو
// خودی ئەپەکەدایە (ناچارین، چونکە backend ـمان نییە بۆ دانانی
// کلیلی تایبەت بۆ هەر بەکارهێنەرێک). ئەمە باشترە لە هیچ —
// فایلەکە encrypted ـە و لە فۆڵدەرێکی تایبەتی ئەپدایە (نابینرێت
// لە File Manager ـی ئاسایی)، بەڵام دژی هێرشێکی وردی تەکنیکی
// (reverse engineering) نییە. پاراستنی تەواو پێویستی بە
// backend ـێکی زیاترە.

final _protectedFileKey =
    enc.Key.fromUtf8('ZnarAcademy2026!ProtectedFile!!!'); // 32 pît
final _protectedFileIv = enc.IV.fromUtf8('ZnarAcademyIVxxx'); // 16 pît

Future<Directory> _protectedFilesDir() async {
  final dir = await getApplicationSupportDirectory();
  final protectedDir = Directory('${dir.path}/protected_content');
  if (!await protectedDir.exists()) {
    await protectedDir.create(recursive: true);
  }
  return protectedDir;
}

Future<File> _protectedFilePath(String productId) async {
  final dir = await _protectedFilesDir();
  return File('${dir.path}/$productId.enc');
}

/// ئایا کۆپیایەکی encrypted ی ئۆفلاین بۆ ئەم بەرهەمە هەیە؟
Future<bool> hasOfflineProtectedCopy(String productId) async {
  final file = await _protectedFilePath(productId);
  return file.exists();
}

/// داگرتن، Encrypt کردن، و خەزنکردنی PDF بۆ بەکارهێنانی ئۆفلاین.
Future<void> saveProtectedPdfOffline({
  required String productId,
  required String pdfUrl,
}) async {
  final response = await http.get(Uri.parse(pdfUrl));
  if (response.statusCode != 200) {
    throw Exception('نەتوانرا فایلەکە داگیرێت (${response.statusCode})');
  }

  final encrypter =
      enc.Encrypter(enc.AES(_protectedFileKey, mode: enc.AESMode.cbc));
  final encrypted =
      encrypter.encryptBytes(response.bodyBytes, iv: _protectedFileIv);

  final file = await _protectedFilePath(productId);
  await file.writeAsBytes(encrypted.bytes);
}

/// خوێندنەوە و Decrypt کردنی کۆپیای ئۆفلاینی پاراستراو، بۆ
/// پیشاندان لەناو SfPdfViewer.memory() (هەرگیز بە شێوەی plain
/// نانووسرێتەوە بۆ دیسک).
Future<Uint8List?> loadProtectedPdfOffline(String productId) async {
  final file = await _protectedFilePath(productId);
  if (!await file.exists()) return null;

  final bytes = await file.readAsBytes();
  final encrypter =
      enc.Encrypter(enc.AES(_protectedFileKey, mode: enc.AESMode.cbc));
  final decrypted = encrypter.decryptBytes(
    enc.Encrypted(bytes),
    iv: _protectedFileIv,
  );
  return Uint8List.fromList(decrypted);
}

Future<void> deleteProtectedPdfOffline(String productId) async {
  final file = await _protectedFilePath(productId);
  if (await file.exists()) await file.delete();
}

// ============================================================
// SUPABASE STORAGE CONFIG
// ============================================================
// لە supabase.com پڕۆژەیەکی نوێ (بەخۆڕایی) دروست بکە، پاشان
// Settings → API → لێرە Project URL و anon/public key کۆپی
// بکە. دواتر لە Storage → Create bucket، ئەم سێ bucketـە
// دروست بکە: receipts, covers, pdfs (هەر سێیان Public بکە
// ئەگەر دەتەوێت لینکەکان ڕاستەوخۆ کاربکەن بەبێ Auth زیاتر).
class SupabaseConfig {
  static const String url =
      'https://dstqivhkenstqdzsowcr.supabase.co';
  static const String anonKey =
      'sb_publishable_1lowQScQL3w_2-wv2CiEuA_DnwzlS21';
}

/// فایلێک بار دەکات بۆ Supabase Storage و لینکی گشتی (public
/// URL) ـی دەگەڕێنێتەوە. bucket دەبێت پێشتر لە Supabase
/// Dashboard دروستکرابێت.
Future<String> uploadToSupabase({
  required String bucket,
  required String path,
  required File file,
}) async {
  final storage = Supabase.instance.client.storage.from(bucket);

  await storage.upload(
    path,
    file,
    fileOptions: const FileOptions(upsert: true),
  );

  return storage.getPublicUrl(path);
}

/// وێنەیەک دەکاتە بڕی (crop) بەپێی ڕێژەی دیاریکراو (ratioX:ratioY)،
/// تاکو بەکارهێنەر خۆی بتوانێت دیاری بکات کام بەشی وێنەکە دەردەکەوێت
/// — لەبری ئەوەی بە شێوەی ئۆتۆماتیکی (BoxFit.cover) بڕدرێت. ئەگەر
/// بەکارهێنەر پاشگەزبووەوە، null دەگەڕێنێتەوە.
Future<File?> cropImageWithRatio(
  String sourcePath, {
  required double ratioX,
  required double ratioY,
  String title = 'گۆڕینی وێنە',
}) async {
  final cropped = await ImageCropper().cropImage(
    sourcePath: sourcePath,
    aspectRatio: CropAspectRatio(ratioX: ratioX, ratioY: ratioY),
    compressQuality: 90,
    uiSettings: [
      AndroidUiSettings(
        toolbarTitle: title,
        toolbarColor: primaryBlue,
        toolbarWidgetColor: Colors.white,
        activeControlsWidgetColor: primaryBlue,
        initAspectRatio: CropAspectRatioPreset.original,
        lockAspectRatio: true,
      ),
      IOSUiSettings(
        title: title,
        aspectRatioLockEnabled: true,
        aspectRatioPickerButtonHidden: true,
        resetAspectRatioEnabled: false,
      ),
    ],
  );

  if (cropped == null) return null;
  return File(cropped.path);
}



/// ئەم فەنکشنە کاتێک بانگ دەکرێت کە پەیامێکی نوێ گەیشتووە لە
/// کاتێکدا ئەپەکە لە پاشەوەیە (background) یان بە تەواوی
/// داخراوە. دەبێت لە دەرەوەی هەر class ـێک بێت (top-level) و
/// ئەم پراگمایە هەبێت، وەک داوای Firebase.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
}

/// کلیلی گشتی (global) بۆ Navigator، بۆ ئەوەی بتوانین SnackBar
/// پیشان بدەین کاتێک پەیامێک دێت لە کاتێکدا ئەپەکە کراوەیە،
/// بەبێ پێویست بە BuildContext ی تایبەت بە هەر پەڕەیەک.
final GlobalKey<NavigatorState> rootNavigatorKey =
    GlobalKey<NavigatorState>();

bool _notificationsInitialized = false;

/// داواکردنی مۆڵەت، وەرگرتن و خەزنکردنی FCM token ـی ئەم
/// ئامێرە لە ژێر بەڵگەنامەی بەکارهێنەر، و گوێگرتن لە پەیامەکانی
/// نوێ کاتێک ئەپەکە کراوەیە. پێویستە دوای چوونەژوورەوە بانگ
/// بکرێت (کاتێک user.uid بەردەستە).
Future<void> setupPushNotifications() async {
  if (_notificationsInitialized) return;
  _notificationsInitialized = true;

  final messaging = FirebaseMessaging.instance;

  await messaging.requestPermission(
    alert: true,
    badge: true,
    sound: true,
  );

  await _saveFcmToken();
  messaging.onTokenRefresh.listen((_) => _saveFcmToken());

  // بەشداریکردن لە topic ی گشتی، بۆ ئەوەی ڕاگەیاندنی هاوبەش
  // (بەرهەمی نوێ، وەشانی نوێ، ڕاگەیاندنی ئەدمین) بگاتە هەموو
  // بەکارهێنەران بەبێ پێویست بە ناردنی تاک‌بەتاک بۆ هەر token ـێک.
  await messaging.subscribeToTopic('all_users');

  // ئەگەر ئەم بەکارهێنەرە ئەدمینە، بەشداری لە topic ی تایبەتی
  // 'admin_alerts' بکە، بۆ ئەوەی تەنها ئەدمین ئاگادار بێتەوە
  // کاتێک کڕیارێک بەرهەمێک دەکڕێت (بڕوانە createOrder).
  try {
    if (await isCurrentUserAdmin()) {
      await messaging.subscribeToTopic('admin_alerts');
    }
  } catch (_) {
    // پشکنینی ئەدمین شکستی هێنا (وەک نبوونی ئینتەرنێت)؛ ئەم
    // بەشداریکردنە پەلاماری دەستپێکردنی ئەپەکە ناوەستێنین.
  }

  // کاتێک ئەپەکە کراوەیە (foreground) و پەیامێک دێت، Firebase
  // خۆی هیچ notification ـێکی سیستەم پیشان نادات، بۆیە بە
  // دەستی SnackBar پیشان دەدەین.
  FirebaseMessaging.onMessage.listen((message) {
    final title = message.notification?.title;
    final body = message.notification?.body;
    if (title == null && body == null) return;

    final context = rootNavigatorKey.currentContext;
    if (context == null) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title != null)
              Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            if (body != null) Text(body),
          ],
        ),
      ),
    );
  });
}

Future<void> _saveFcmToken() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;

  try {
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null) return;

    await FirebaseFirestore.instance.collection('users').doc(user.uid).set(
      {'fcmToken': token},
      SetOptions(merge: true),
    );
  } catch (_) {
    // ئەگەر وەرگرتنی token شکستی هێنا (وەک لەسەر ئیمولەیتەرێکی
    // بەبێ Google Play Services)، پەلاماردانی ئەپەکە ناوەستێنین.
  }
}

// ============================================================
// NOTIFICATIONS INBOX (بۆ ئایکۆنی زەنگ لە Home)
// ============================================================
// AdminSendNotificationScreen ڕاگەیاندنەکان لە کۆلیکشنی
// 'broadcasts' خەزن دەکات. ئێرە ئەو ڕاگەیاندنانە دەخوێنینەوە
// بۆ پیشاندان لە شێوەی inbox ـێک لەناو ئەپەکە (سەرباری
// push notification ـی سیستەم).

Stream<List<Map<String, dynamic>>> broadcastsStream() {
  return FirebaseFirestore.instance
      .collection('broadcasts')
      .snapshots()
      .map((snap) {
    final items = snap.docs.map((d) => {...d.data(), 'id': d.id}).toList();
    items.sort((a, b) {
      final ta = a['createdAt'];
      final tb = b['createdAt'];
      if (ta is! Timestamp || tb is! Timestamp) return 0;
      return tb.compareTo(ta);
    });
    return items;
  });
}

Future<DateTime?> lastSeenNotificationsAt() async {
  final prefs = await SharedPreferences.getInstance();
  final millis = prefs.getInt('notifications_last_seen');
  if (millis == null) return null;
  return DateTime.fromMillisecondsSinceEpoch(millis);
}

Future<void> markNotificationsSeenNow() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(
    'notifications_last_seen',
    DateTime.now().millisecondsSinceEpoch,
  );
}

// ============================================================
// CUSTOM FILE REQUESTS (داواکاریا فایلان)
// ============================================================
// قوتابی دەتوانێت داواکارییەکی تایبەت بنێرێت (بۆ نموونە:
// "تێمپلەیتێکی سیمینار لەسەر بابەتی X پێویستە"). ئەدمین
// هەموو داواکارییەکان لە Admin Panel دەبینێت تاکو بزانێت
// قوتابی پێداویستی چی هەیە.

CollectionReference<Map<String, dynamic>> _fileRequestsRef() =>
    FirebaseFirestore.instance.collection('fileRequests');

Future<void> submitFileRequest({
  required String title,
  required String description,
}) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) throw Exception('پێویستە بچیتە ژوورەوە.');

  await _fileRequestsRef().add({
    'userId': user.uid,
    'userEmail': user.email,
    'title': title.trim(),
    'description': description.trim(),
    'status': 'pending', // pending | fulfilled
    'createdAt': FieldValue.serverTimestamp(),
  });
}

List<Map<String, dynamic>> _sortRequestsByDate(
  List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
) {
  final items = docs.map((d) => {...d.data(), 'id': d.id}).toList();
  items.sort((a, b) {
    final ta = a['createdAt'];
    final tb = b['createdAt'];
    if (ta is! Timestamp || tb is! Timestamp) return 0;
    return tb.compareTo(ta);
  });
  return items;
}

Stream<List<Map<String, dynamic>>> myFileRequestsStream() {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return Stream.value(<Map<String, dynamic>>[]);

  return _fileRequestsRef()
      .where('userId', isEqualTo: user.uid)
      .snapshots()
      .map((snap) => _sortRequestsByDate(snap.docs));
}

Stream<List<Map<String, dynamic>>> allFileRequestsStream() {
  return _fileRequestsRef()
      .snapshots()
      .map((snap) => _sortRequestsByDate(snap.docs));
}

Stream<int> pendingFileRequestsCountStream() {
  return allFileRequestsStream().map(
    (items) => items.where((r) => r['status'] != 'fulfilled').length,
  );
}

Future<void> setFileRequestFulfilled(String id, bool fulfilled) async {
  await _fileRequestsRef().doc(id).update({
    'status': fulfilled ? 'fulfilled' : 'pending',
  });
}

/// هەموو هەڵەیەکی نەگیراو (uncaught) کە لە هەر شوێنێکی ئەپەکە
/// ڕوودەدات، تۆمار دەکات. لە داهاتوودا دەتوانرێت پەیوەندی بە
/// خزمەتگوزارییەکی وەک Crashlytics/Sentry بکرێت، بەڵام بۆ ئێستا
/// تەنها لە debug console ـدا دەردەکەوێت تاکو ئەپەکە بەبێ هیچ
/// ئاگاداریی نەڕوخێت.
void _reportError(Object error, StackTrace stack) {
  debugPrint('🔴 Uncaught error: $error\n$stack');
}

Future<void> main() async {
  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // هەڵەکانی widget tree (وەک نەبوونی داتا لە build ـدا) لە
    // جیاتی ڕوخانی هەموو ئەپەکە (red screen)، تۆمار دەکرێن.
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      _reportError(details.exception, details.stack ?? StackTrace.empty);
    };

    // لە دۆخی release ـدا، لەجیاتی "red screen of death"،
    // پەیامێکی سادەی کوردی پیشان دەدرێت بۆ بەکارهێنەر.
    if (kReleaseMode) {
      ErrorWidget.builder = (FlutterErrorDetails details) {
        return Material(
          color: const Color(0xFFFFF5F5),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    color: Colors.redAccent,
                    size: 40,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'هەڵەیەک ڕوویدا',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
        );
      };
    }

    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    // App Check: پاراستنی Firebase (Firestore/Storage/Functions)
    // لە داواکارییە ناڕەواکان (bots، سکریپتی دەرەکی، هتد) —
    // تەنها داواکارییەکانی ڕاستەقینەی ئەپەکە قبوڵ دەکات. لە
    // دۆخی debug ـدا provider ـی debug بەکاردێت (پێویستی بە
    // تۆمارکردنی debug token هەیە لە Firebase Console)، لە
    // دۆخی release ـدا Play Integrity (ئەندرۆید) بەکاردێت.
    try {
      await FirebaseAppCheck.instance.activate(
        androidProvider:
            kDebugMode ? AndroidProvider.debug : AndroidProvider.playIntegrity,
        appleProvider: kDebugMode
            ? AppleProvider.debug
            : AppleProvider.appAttestWithDeviceCheckFallback,
      );
    } catch (e) {
      // App Check شکستی هێنا (بۆ نموونە لەسەر وێب یان platform ـێکی
      // پشتگیرینەکراو) — ئەپەکە بەردەوام دەبێت بەبێ ئەم پاراستنە،
      // نەک بشکێت.
      debugPrint('⚠️ App Check activation failed: $e');
    }

    // پێویستە پێش runApp() بانگ بکرێت، تاکو ئەگەر ئەپەکە داخراو
    // بوو یان لە پاشەوە بوو، پەیامەکان وەربگیرێن.
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // Supabase تەنها بۆ Storage (بارکردنی وەسڵ/بەرگ/PDF)
    // بەکاردێت، چونکە Firebase Storage پشتگیری ناوچەی عێراق
    // ناکات. Auth و Firestore هەر بە Firebase دەمێننەوە.
    await Supabase.initialize(
      url: SupabaseConfig.url,
      anonKey: SupabaseConfig.anonKey,
    );

    // یەکەم جار کە ئەپەکە ڕادەکات، ئەگەر کۆلیکشنی 'products'
    // بەتاڵ بێت، بەرهەمە نموونەییەکان بۆی بار دەکات.
    await seedProductsIfEmpty();
    await seedCategoriesIfEmpty();
    await seedBannersIfEmpty();
    await loadSavedThemeMode();

    runApp(const ZnarAcademyApp());
  }, _reportError);
}

// ============================================================
// APP
// ============================================================

class ZnarAcademyApp extends StatelessWidget {
  const ZnarAcademyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Locale>(
      valueListenable: localeNotifier,
      builder: (context, locale, child) {
        final isRtl =
            locale.languageCode == 'ku' ||
            locale.languageCode == 'ar';

        return ValueListenableBuilder<ThemeMode>(
          valueListenable: themeModeNotifier,
          builder: (context, mode, _) {
            return MaterialApp(
          navigatorKey: rootNavigatorKey,
          debugShowCheckedModeBanner: false,
          title: 'ZNAR Academy',

          locale: locale,

          supportedLocales: const [
           Locale('ku'),
           Locale('ar'),
           Locale('en'),
          ],

          localizationsDelegates: const [
           AppLocalizationsDelegate(),
           ZnarMaterialLocalizationsDelegate(),
           GlobalWidgetsLocalizations.delegate,
           GlobalCupertinoLocalizations.delegate,
          ],

          builder: (context, child) {
            return Directionality(
              textDirection:
                  isRtl ? TextDirection.rtl : TextDirection.ltr,
              child: child!,
            );
          },

          themeMode: mode,

          theme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.light,
            fontFamily: 'Arial',
            scaffoldBackgroundColor: const Color(0xFFF8FAFC),
            colorScheme: ColorScheme.fromSeed(
              seedColor: primaryBlue,
              brightness: Brightness.light,
            ),
            appBarTheme: AppBarTheme(
              backgroundColor: Colors.transparent,
              elevation: 0,
              surfaceTintColor: Colors.transparent,
              iconTheme: const IconThemeData(color: Color(0xFF0F172A)),
              titleTextStyle: const TextStyle(
                color: Color(0xFF0F172A),
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            snackBarTheme: SnackBarThemeData(
              behavior: SnackBarBehavior.floating,
              backgroundColor: const Color(0xFF0F172A),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              contentTextStyle: const TextStyle(color: Colors.white),
            ),
            splashFactory: InkRipple.splashFactory,
            highlightColor: primaryBlue.withValues(alpha: 0.05),
          ),

          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            fontFamily: 'Arial',
            scaffoldBackgroundColor: const Color(0xFF0B1220),
            colorScheme: ColorScheme.fromSeed(
              seedColor: primaryBlue,
              brightness: Brightness.dark,
            ),
            appBarTheme: AppBarTheme(
              backgroundColor: Colors.transparent,
              elevation: 0,
              surfaceTintColor: Colors.transparent,
              iconTheme: const IconThemeData(color: Color(0xFFF1F5F9)),
              titleTextStyle: const TextStyle(
                color: Color(0xFFF1F5F9),
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            snackBarTheme: SnackBarThemeData(
              behavior: SnackBarBehavior.floating,
              backgroundColor: const Color(0xFF1E293B),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              contentTextStyle: const TextStyle(color: Colors.white),
            ),
            splashFactory: InkRipple.splashFactory,
            highlightColor: primaryBlue.withValues(alpha: 0.08),
          ),

          home: const SplashScreen(),
            );
          },
        );
      },
    );
  }
}

// ============================================================
// LOCALIZATION
// ============================================================

class AppLocalizations {
  final Locale locale;

  AppLocalizations(this.locale);

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(
          context,
          AppLocalizations,
        ) ??
        AppLocalizations(const Locale('ku'));
  }

  static const Map<String, Map<String, String>> _values = {
    'ku': {
      'welcome': 'بخێەهاتی بۆ ZNAR Academy',
      'loginSubtitle': 'چوونا ژوورێ ',
      'email': 'ئیمەیڵ',
      'password': 'پەیڤا نهێنی',
      'passwordForgot': 'پەیڤا نهێنیت لەبیرکردووە؟',
      'login': 'چوونا ژوورێ',
      'noAccount': 'هەژمار نێنە؟',
      'create': 'دروست بکە',
      'name': 'ناڤ',
      'yourName': 'ناڤێ تە',
      'createAccount': 'دروستکردنا ئەکاونت',
      'passwordHint': ' 8 پیت + هێمایەک',
      'passwordRule':
          'پەیڤا نهێنی دڤێت  8 پیت بێت و هێمایەکی تایبەت تێدا بێت.',
      'acceptTerms': 'مەرج و یاساکان قبوڵ دکەم',
      'forgotPassword': 'پەیڤا نهێنی',
      'forgotDescription':
          'ئیمەیڵێ خو بنڤیسە بۆ هنارتنا لینکێ گهورینا پەیڤا نهێنی.',
      'sendLink': 'هنارتنا لینک',

      'home': 'سەرەکی',
      'search': 'گەڕان',
      'library': 'پەرتوکخانە',
      'favorites': 'دڵخواز',
      'profile': 'پڕۆفایل',

      'hello': 'بخێرهاتی 👋',
      'searchProduct': 'لێگەریان...',
      'newProducts': 'بەرهەمێن نوی',
      'specialDiscount': 'داشکاندنێن تایبەت',
      'academicBooksReports': 'پەرتوک و ڕاپۆرتێن ئەکادیمی',
      'academicNeeds':
          'هەموو پێداویستییە ئەکادیمییەکانت لە یەک شوێن.',
      'categories': 'بەش',
      'all': 'هەمی',
      'discount': 'داشکاندنەک تایبەت 🎁',
      'useCoupon': 'کۆدی ZNAR20 بکاربینە',

      'book': 'پەرتوک',
      'report': 'ڕاپۆرت',
      'research': 'توێژینەوە',
      'seminar': 'سیمینار',
      'template': 'تێمپلەیت',
      'cv': 'CV',

      'productDetails': 'وردەکاریی بەرهەم',
      'aboutProduct': 'دەربارەی بەرهەم',
      'author': 'نڤیسەر',
      'preview': 'دیتن Preview',
      'buyNow': 'کڕین ',
      'previewEnd': 'Preview دوماهیک هات 🔒',
      'threePages':
          'تەنها ٣ پەڕێن یەکەم بۆ Preview بەردەستە.',
      'buyForFull':
          'بۆ دەستگەهشتن بە تەواوی بەرهەمەکە، تکایە بیکڕە.',
      'buyProduct': 'کڕینی بەرهەم',
      'backToPreview': 'گەڕانەوە بۆ Preview',

      'purchaseConfirmation': 'پشتڕاستکرنا کڕین',
      'couponCode': 'کۆدی کۆپۆن',
      'apply': 'جێبەجێکردن',
      'discountApplied': '20% داشکاندن هاتە جێبەجێکرن.',
      'total': 'کۆی گشتی:',
      'continuePayment': 'بەردەوامبوون بۆ پارەدان',

      'products': 'بەرهەمەکان',
      'libraryEmpty':
          'دوای کڕینی بەرهەمەکان لێرە پیشان دەدرێن.',
      'favoritesEmpty':
          'بەرهەمە دڵخوازەکانت لێرە دەبینیت.',

      'settings': 'ڕێکخستنەکان',
      'language': 'زمان',
      'darkLight': 'Dark / Light Mode',
      'help': 'یارمەتی',
      'logout': 'چوونەدەرەوە',
      'student': 'خوێندکار',

      'languageTitle': 'زمانی ئەپ',
      'kurdish': 'کوردی بادینی',
      'arabic': 'عەرەبی',
      'english': 'English',
      'cancel': 'هەڵوەشاندنەوە',

      'invalidPassword':
          'وشەی نهێنی دەبێت لانیکەم 8 پیت و هێمایەکی تایبەتی هەبێت.',
      'acceptTermsMessage':
          'تکایە مەرج و یاساکان قبوڵ بکە.',
      'pdfNotAvailable':
          'PDF ـی ئەم بەرهەمە هێشتا زیاد نەکراوە.',
      'futureFirebase':
          'لە داهاتوودا بە Firebase Authentication جێبەجێ دەکرێت.',
      'couponSuccess':
          'کۆپۆنی ZNAR20 بە سەرکەوتوویی جێبەجێ کرا. 20% تخفیف 🎉',
      'invalidCoupon':
          'کۆدی کۆپۆن دروست نییە.',
      'futureFib':
          'لە هەنگاوی داهاتوودا FIB Payment لێرە جێبەجێ دەکرێت.',
    },

    'ar': {
      'welcome': 'مرحباً بك في ZNAR Academy',
      'loginSubtitle': 'تسجيل الدخول إلى حسابك',
      'email': 'البريد الإلكتروني',
      'password': 'كلمة المرور',
      'passwordForgot': 'هل نسيت كلمة المرور؟',
      'login': 'تسجيل الدخول',
      'noAccount': 'ليس لديك حساب؟',
      'create': 'إنشاء حساب',
      'name': 'الاسم',
      'yourName': 'اسمك',
      'createAccount': 'إنشاء الحساب',
      'passwordHint': '8 أحرف على الأقل + رمز',
      'passwordRule':
          'يجب أن تحتوي كلمة المرور على 8 أحرف على الأقل ورمز خاص.',
      'acceptTerms': 'أوافق على الشروط والأحكام',
      'forgotPassword': 'كلمة المرور',
      'forgotDescription':
          'أدخل بريدك الإلكتروني لإرسال رابط تغيير كلمة المرور.',
      'sendLink': 'إرسال الرابط',

      'home': 'الرئيسية',
      'search': 'البحث',
      'library': 'المكتبة',
      'favorites': 'المفضلة',
      'profile': 'الملف الشخصي',

      'hello': 'مرحباً 👋',
      'searchProduct': 'ابحث عن منتج...',
      'newProducts': 'منتجات جديدة',
      'specialDiscount': 'خصومات خاصة',
      'academicBooksReports': 'كتب وتقارير أكاديمية',
      'academicNeeds':
          'جميع احتياجاتك الأكاديمية في مكان واحد.',
      'categories': 'الأقسام',
      'all': 'الكل',
      'discount': 'خصم خاص 🎁',
      'useCoupon': 'استخدم كود ZNAR20',

      'book': 'كتاب',
      'report': 'تقرير',
      'research': 'بحث',
      'seminar': 'سيمينار',
      'template': 'قالب',
      'cv': 'السيرة الذاتية',

      'productDetails': 'تفاصيل المنتج',
      'aboutProduct': 'عن المنتج',
      'author': 'المؤلف',
      'preview': 'معاينة Preview',
      'buyNow': 'شراء الآن',
      'previewEnd': 'انتهت المعاينة 🔒',
      'threePages':
          'الصفحات الثلاث الأولى فقط متاحة للمعاينة.',
      'buyForFull':
          'للوصول إلى المنتج كاملاً، يرجى شراؤه.',
      'buyProduct': 'شراء المنتج',
      'backToPreview': 'العودة إلى المعاينة',

      'purchaseConfirmation': 'تأكيد الشراء',
      'couponCode': 'رمز الخصم',
      'apply': 'تطبيق',
      'discountApplied': 'تم تطبيق خصم 20%.',
      'total': 'المجموع:',
      'continuePayment': 'متابعة الدفع',

      'products': 'المنتجات',
      'libraryEmpty':
          'ستظهر المنتجات هنا بعد الشراء.',
      'favoritesEmpty':
          'ستظهر المنتجات المفضلة هنا.',

      'settings': 'الإعدادات',
      'language': 'اللغة',
      'darkLight': 'الوضع الداكن / الفاتح',
      'help': 'المساعدة',
      'logout': 'تسجيل الخروج',
      'student': 'طالب',

      'languageTitle': 'لغة التطبيق',
      'kurdish': 'الكردية البادينية',
      'arabic': 'العربية',
      'english': 'English',
      'cancel': 'إلغاء',

      'invalidPassword':
          'يجب أن تحتوي كلمة المرور على 8 أحرف على الأقل ورمز خاص.',
      'acceptTermsMessage':
          'يرجى الموافقة على الشروط والأحكام.',
      'pdfNotAvailable':
          'لم تتم إضافة ملف PDF لهذا المنتج بعد.',
      'futureFirebase':
          'سيتم تنفيذها لاحقاً باستخدام Firebase Authentication.',
      'couponSuccess':
          'تم تطبيق كود ZNAR20 بنجاح. خصم 20% 🎉',
      'invalidCoupon':
          'رمز الخصم غير صحيح.',
      'futureFib':
          'سيتم تنفيذ الدفع عبر FIB في الخطوة القادمة.',
    },

    'en': {
      'welcome': 'Welcome to ZNAR Academy',
      'loginSubtitle': 'Sign in to your account',
      'email': 'Email',
      'password': 'Password',
      'passwordForgot': 'Forgot your password?',
      'login': 'Sign In',
      'noAccount': 'Don’t have an account?',
      'create': 'Create one',
      'name': 'Name',
      'yourName': 'Your name',
      'createAccount': 'Create Account',
      'passwordHint': 'At least 8 characters + a symbol',
      'passwordRule':
          'Password must contain at least 8 characters and one special symbol.',
      'acceptTerms': 'I agree to the terms and conditions',
      'forgotPassword': 'Password',
      'forgotDescription':
          'Enter your email to receive a password reset link.',
      'sendLink': 'Send Link',

      'home': 'Home',
      'search': 'Search',
      'library': 'Library',
      'favorites': 'Favorites',
      'profile': 'Profile',

      'hello': 'Welcome 👋',
      'searchProduct': 'Search for a product...',
      'newProducts': 'New Products',
      'specialDiscount': 'Special Discounts',
      'academicBooksReports': 'Academic Books & Reports',
      'academicNeeds':
          'All your academic needs in one place.',
      'categories': 'Categories',
      'all': 'All',
      'discount': 'Special Discount 🎁',
      'useCoupon': 'Use code ZNAR20',

      'book': 'Book',
      'report': 'Report',
      'research': 'Research',
      'seminar': 'Seminar',
      'template': 'Template',
      'cv': 'CV',

      'productDetails': 'Product Details',
      'aboutProduct': 'About the Product',
      'author': 'Author',
      'preview': 'Preview',
      'buyNow': 'Buy Now',
      'previewEnd': 'Preview Ended 🔒',
      'threePages':
          'Only the first 3 pages are available for preview.',
      'buyForFull':
          'Please purchase the product to access it completely.',
      'buyProduct': 'Buy Product',
      'backToPreview': 'Back to Preview',

      'purchaseConfirmation': 'Purchase Confirmation',
      'couponCode': 'Coupon Code',
      'apply': 'Apply',
      'discountApplied': '20% discount applied.',
      'total': 'Total:',
      'continuePayment': 'Continue to Payment',

      'products': 'Products',
      'libraryEmpty':
          'Purchased products will appear here.',
      'favoritesEmpty':
          'Your favorite products will appear here.',

      'settings': 'Settings',
      'language': 'Language',
      'darkLight': 'Dark / Light Mode',
      'help': 'Help',
      'logout': 'Log Out',
      'student': 'Student',

      'languageTitle': 'App Language',
      'kurdish': 'Badini Kurdish',
      'arabic': 'Arabic',
      'english': 'English',
      'cancel': 'Cancel',

      'invalidPassword':
          'Password must contain at least 8 characters and one special symbol.',
      'acceptTermsMessage':
          'Please accept the terms and conditions.',
      'pdfNotAvailable':
          'PDF has not been added for this product yet.',
      'futureFirebase':
          'This will be implemented later using Firebase Authentication.',
      'couponSuccess':
          'ZNAR20 coupon applied successfully. 20% discount 🎉',
      'invalidCoupon':
          'Invalid coupon code.',
      'futureFib':
          'FIB Payment will be implemented in the next step.',
    },
  };

  String get(String key) {
    return _values[locale.languageCode]?[key] ??
        _values['ku']![key] ??
        key;
  }
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    return ['ku', 'ar', 'en'].contains(locale.languageCode);
  }

  @override
  Future<AppLocalizations> load(Locale locale) async {
    return AppLocalizations(locale);
  }

  @override
  bool shouldReload(
    covariant LocalizationsDelegate<AppLocalizations> old,
  ) {
    return false;
  }
}

// ============================================================
// COLORS
// ============================================================

const Color primaryBlue = Color(0xFF2563EB);
const Color secondaryPurple = Color(0xFF7C3AED);
const Color successColor = Color(0xFF16A34A);
const Color errorColor = Color(0xFFDC2626);
const Color accentGold = Color(0xFFF59E0B);

/// ئایا ئێستا دۆخی تاریکە؟ ئەگەر themeModeNotifier لەسەر
/// System بوو، برایتنێسی سیستەمی ئامێرەکە دەپشکنین.
bool get isDarkMode {
  if (themeModeNotifier.value == ThemeMode.dark) return true;
  if (themeModeNotifier.value == ThemeMode.light) return false;
  return WidgetsBinding.instance.platformDispatcher.platformBrightness ==
      Brightness.dark;
}

/// ئەم چوار "token" ـە دیزاینییە ئێستا getter ـن (نەک const)
/// تاکو بەپێی isDarkMode ڕەنگیان بگۆڕدرێت. بۆیە لە هەموو
/// شوێنێک کە بەکاردێن، پێویستە 'const' لابدرێت.
Color get backgroundColor =>
    isDarkMode ? const Color(0xFF0B1220) : const Color(0xFFF8FAFC);
Color get darkText =>
    isDarkMode ? const Color(0xFFF1F5F9) : const Color(0xFF0F172A);
Color get secondaryText =>
    isDarkMode ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
Color get cardBorderColor =>
    isDarkMode ? const Color(0xFF1E293B) : const Color(0xFFEEF2F7);
Color get cardSurfaceColor =>
    isDarkMode ? const Color(0xFF141B2E) : Colors.white;

// ============================================================
// DESIGN SYSTEM (Gradients / Shadows / Radius)
// ============================================================
// ئەم بەشە بنچینەی دیزاینی نوێی ئەپەکەیە، بۆ ئەوەی هەموو
// screen و widgetـەکان یەک style و یەک ڕەنگی هاوسەنگ بەکاربێنن.

const LinearGradient brandGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [primaryBlue, secondaryPurple],
);

const double kRadiusSm = 14;
const double kRadiusMd = 20;
const double kRadiusLg = 28;

List<BoxShadow> softShadow({double opacity = 0.06, double blur = 20}) {
  return [
    BoxShadow(
      color: Colors.black.withValues(alpha: opacity),
      blurRadius: blur,
      offset: const Offset(0, 8),
    ),
  ];
}

BoxDecoration softCardDecoration({
  Color? color,
  double radius = kRadiusMd,
  bool bordered = true,
}) {
  return BoxDecoration(
    color: color ?? cardSurfaceColor,
    borderRadius: BorderRadius.circular(radius),
    border: bordered ? Border.all(color: cardBorderColor, width: 1) : null,
    boxShadow: softShadow(),
  );
}

// ------------------------------------------------------------
// PRIMARY GRADIENT BUTTON (shared across the app)
// ------------------------------------------------------------

class GradientButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool isLoading;
  final IconData? icon;
  final double height;

  const GradientButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.isLoading = false,
    this.icon,
    this.height = 56,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: onPressed == null && !isLoading
              ? null
              : brandGradient,
          color: onPressed == null && !isLoading
              ? Colors.grey.shade300
              : null,
          borderRadius: BorderRadius.circular(kRadiusSm),
          boxShadow: onPressed == null
              ? []
              : [
                  BoxShadow(
                    color: primaryBlue.withValues(alpha: 0.30),
                    blurRadius: 16,
                    offset: const Offset(0, 8),
                  ),
                ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(kRadiusSm),
            onTap: isLoading ? null : onPressed,
            child: Center(
              child: isLoading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (icon != null) ...[
                          Icon(icon, color: Colors.white, size: 20),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          label,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------
// EMPTY STATE (shared across Library / Favorites / Search)
// ------------------------------------------------------------

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;

  const EmptyState({
    super.key,
    required this.icon,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    // ئەگەر بەرزی دیاریکراو هەبێت، لەناو scroll view دادەنرێت بۆ ئەوەی
    // بتوانرێت "بکێشە خوارەوە بۆ نوێکردنەوە" (Pull-to-refresh) لەسەری
    // بکرێت، تەنانەت کاتێک لیستەکە بەتاڵە.
    return LayoutBuilder(
      builder: (context, constraints) {
        final content = _content();
        if (!constraints.hasBoundedHeight) return content;
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: content,
          ),
        );
      },
    );
  }

  Widget _content() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 92,
              height: 92,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    primaryBlue.withValues(alpha: 0.10),
                    secondaryPurple.withValues(alpha: 0.10),
                  ],
                ),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 40, color: primaryBlue),
            ),
            const SizedBox(height: 18),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: secondaryText,
                fontSize: 14.5,
                height: 1.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// REFRESH + LOADING HELPERS
// ============================================================

/// نوێکردنەوەی ڕاستەقینە: داتا لە سێرڤەرەوە (Source.server) دەهێنێت،
/// بەم شێوەیە هەموو stream ـەکان نوێترین داتا وەردەگرن. ئەگەر
/// ئینتەرنێت نەبوو، false دەگەڕێنێتەوە.
Future<bool> pullRefresh(
  Iterable<Query<Map<String, dynamic>>?> queries,
) async {
  final started = DateTime.now();
  var ok = true;

  try {
    await Future.wait(
      queries
          .whereType<Query<Map<String, dynamic>>>()
          .map((q) => q.get(const GetOptions(source: Source.server))),
    );
  } catch (_) {
    ok = false;
  }

  // بۆ ئەوەی ئەنیمەیشنی نوێکردنەوە بەکارهێنەر ببینێت.
  const minDuration = Duration(milliseconds: 500);
  final elapsed = DateTime.now().difference(started);
  if (elapsed < minDuration) {
    await Future.delayed(minDuration - elapsed);
  }

  return ok;
}

/// pullRefresh + پەیامی هەڵە ئەگەر نەتوانرا نوێ بکرێتەوە.
Future<void> refreshWithFeedback(
  BuildContext context,
  Iterable<Query<Map<String, dynamic>>?> queries,
) async {
  final ok = await pullRefresh(queries);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('نەتوانرا نوێ بکرێتەوە. ئینتەرنێتەکەت بپشکنە.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }
}

/// وا دەکات هەموو لیستەکانی ناوەوە بتوانن بکێشرێنە خوارەوە، تەنانەت
/// ئەگەر ناوەڕۆکەکەیان کورت بێت (پێویستە بۆ RefreshIndicator).
class _AlwaysScrollBehavior extends MaterialScrollBehavior {
  const _AlwaysScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return AlwaysScrollableScrollPhysics(
      parent: super.getScrollPhysics(context),
    );
  }
}

/// "بکێشە خوارەوە بۆ نوێکردنەوە" — بۆ هەر لیستێک.
/// [queries]: ئەو کۆلیکشنانەی لە سێرڤەرەوە نوێ دەکرێنەوە.
/// [onRefresh]: ئەگەر پێویستت بە لۆجیکی تایبەت بوو (وەک ئامار).
class AppRefresh extends StatelessWidget {
  final Widget child;
  final List<Query<Map<String, dynamic>>?> queries;
  final Future<void> Function()? onRefresh;

  const AppRefresh({
    super.key,
    required this.child,
    this.queries = const [],
    this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: primaryBlue,
      onRefresh: () {
        if (onRefresh != null) return onRefresh!();
        return refreshWithFeedback(context, queries);
      },
      child: ScrollConfiguration(
        behavior: const _AlwaysScrollBehavior(),
        child: child,
      ),
    );
  }
}

// ============================================================
// APP LOGO (وێنەی ڕاستەقینەی لۆگۆی ئەپەکە)
// ============================================================
//
// پێویستە:
// 1) فایلی logo.png بخەرە ژێر: assets/images/logo1.png
// 2) لە pubspec.yaml، ژێر flutter: → assets: ئەم هێڵە زیاد بکە:
//      - assets/images/logo1.png

class AppLogo extends StatelessWidget {
  final double size;

  const AppLogo({super.key, this.size = 90});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/logo2.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stack) {
        // ئەگەر فایلەکە هێشتا زیاد نەکرابوو، بۆ ئەوەی ئەپەکە
        // خراپ نەبێت، هێمای کۆن وەک پاشەکەوت پیشان دەدرێت.
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            gradient: brandGradient,
            borderRadius: BorderRadius.circular(size * 0.27),
          ),
          child: Center(
            child: Text(
              'Z',
              style: TextStyle(
                color: Colors.white,
                fontSize: size * 0.5,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );
      },
    );
  }
}

// ============================================================
// SPLASH SCREEN
// ============================================================

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  VideoPlayerController? _controller;
  bool _videoFailed = false;
  bool _navigated = false;
  Timer? _fallbackTimer;

  @override
  void initState() {
    super.initState();

    _controller = VideoPlayerController.asset('assets/videos/splash.mp4')
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() {});
        _controller!.play();
        _controller!.addListener(_onVideoTick);
      }).catchError((Object error) {
        // ئەگەر ڤیدیۆکە بار نەکرا (بۆ نموونە هێشتا زیاد نەکراوە
        // بۆ pubspec.yaml)، دەگەڕێینەوە بۆ دیزاینی کۆن (لۆگۆ +
        // گرادیێنت) بەبێ ئەوەی ئەپەکە بشکێت. هەڵەی ڕاستەقینە
        // لە debug console ـدا دەردەکەوێت تاکو بتوانین کێشەکە
        // بدۆزینەوە.
        debugPrint('⚠️ Splash video failed to load: $error');
        if (!mounted) return;
        setState(() => _videoFailed = true);
        _scheduleFallbackNavigation(const Duration(seconds: 2));
      });

    // دڵنیایی زیادە: تەنانەت ئەگەر بەهۆیەکەوە ڤیدیۆکە کۆتایی
    // نەهات، لە ماوەی ٦ چرکەدا بەردەوام دەبین.
    _scheduleFallbackNavigation(const Duration(seconds: 6));
  }

  void _onVideoTick() {
    final value = _controller?.value;
    if (value == null || !value.isInitialized) return;
    if (value.duration > Duration.zero &&
        value.position >= value.duration - const Duration(milliseconds: 150)) {
      _navigateNext();
    }
  }

  void _scheduleFallbackNavigation(Duration delay) {
    _fallbackTimer?.cancel();
    _fallbackTimer = Timer(delay, _navigateNext);
  }

  Future<void> _navigateNext() async {
    if (_navigated || !mounted) return;
    _navigated = true;
    _fallbackTimer?.cancel();

    final prefs = await SharedPreferences.getInstance();
    final seenOnboarding = prefs.getBool('onboarding_seen') ?? false;

    if (!mounted) return;

    Widget next;
    // یەکەم جارە ئەپەکە کراوەتەوە — Onboarding پیشان بدە.
    if (!seenOnboarding) {
      next = const OnboardingScreen();
    } else {
      // ئەگەر بەکارهێنەر پێشتر چوونەژوورەوەی کردبوو (session ـەکەی
      // هێشتا چالاکە)، ڕاستەوخۆ دەچێتە ناو ئەپەکە.
      final isLoggedIn = FirebaseAuth.instance.currentUser != null;
      next = isLoggedIn ? const HomeScreen() : const LoginScreen();
    }

    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 500),
        pageBuilder: (_, animation, __) =>
            FadeTransition(opacity: animation, child: next),
      ),
    );
  }

  @override
  void dispose() {
    _fallbackTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = !_videoFailed &&
        controller != null &&
        controller.value.isInitialized;

    return Scaffold(
      backgroundColor: Colors.black,
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 400),
        child: ready
            ? SizedBox.expand(
                key: const ValueKey('video'),
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: controller.value.size.width,
                    height: controller.value.size.height,
                    child: VideoPlayer(controller),
                  ),
                ),
              )
            : Container(
                key: const ValueKey('fallback'),
                width: double.infinity,
                height: double.infinity,
                decoration: const BoxDecoration(gradient: brandGradient),
                child: Stack(
                  children: [
                    Positioned(
                      top: -60,
                      left: -40,
                      child: Container(
                        width: 180,
                        height: 180,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: -80,
                      right: -60,
                      child: Container(
                        width: 240,
                        height: 240,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.07),
                        ),
                      ),
                    ),
                    Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 110,
                            height: 110,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(30),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.15),
                                  blurRadius: 25,
                                  offset: const Offset(0, 12),
                                ),
                              ],
                            ),
                            child: const Padding(
                              padding: EdgeInsets.all(8),
                              child: AppLogo(size: 94),
                            ),
                          ),
                          const SizedBox(height: 26),
                          const Text(
                            'ZNAR Academy',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 30,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.3,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'پلاتفۆرما ئەکادیمی یا خوێندکاران',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.85),
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 45),
                          const SizedBox(
                            width: 26,
                            height: 26,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2.5,
                            ),
                          ),
                        ],
                      ),
                    ),
          ],
        ),
      ),
      ),
    );
  }
}

// ============================================================
// ONBOARDING
// ============================================================

class _OnboardingPageData {
  final IconData icon;
  final String title;
  final String description;

  const _OnboardingPageData({
    required this.icon,
    required this.title,
    required this.description,
  });
}

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _controller = PageController();
  int _page = 0;

  static const _pages = [
    _OnboardingPageData(
      icon: Icons.auto_stories_rounded,
      title: 'بەخێربێیت بۆ ZNAR Academy',
      description:
          'شوێنێکی یەکگرتوو بۆ هەموو پێداویستییە ئەکادیمییەکانت — '
          'کتێب، ڕاپۆرت، CV و زۆر شتی تر.',
    ),
    _OnboardingPageData(
      icon: Icons.explore_rounded,
      title: 'دۆزینەوەی بەرهەمی جۆراوجۆر',
      description:
          'بگەڕێ بەناو دەیان بەرهەمی ڕێکخراو لە کاتیگۆری جیاواز، '
          'یان ڕاستەوخۆ بگەڕێ بۆ ئەوەی پێویستت پێیەتی.',
    ),
    _OnboardingPageData(
      icon: Icons.visibility_rounded,
      title: 'پێش کڕین، بیبینە',
      description:
          'پێش کڕینی هەر بەرهەمێک، دەتوانیت ٣ پەڕەی یەکەمی '
          'وەک Preview ببینیت — بۆ دڵنیاییت.',
    ),
    _OnboardingPageData(
      icon: Icons.library_books_rounded,
      title: 'هەمیشە لای خۆت',
      description:
          'هەموو بەرهەمە کڕدراوەکانت لە پەرتووکخانەکەتدا دەمێننەوە، '
          'ئامادەن هەرکات پێویستت پێیان بوو.',
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_seen', true);

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  void _next() {
    if (_page == _pages.length - 1) {
      _finish();
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _page == _pages.length - 1;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: isLast
                    ? const SizedBox(height: 40)
                    : TextButton(
                        onPressed: _finish,
                        child: Text(
                          'پەڕاندن',
                          style: TextStyle(
                            color: secondaryText,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _pages.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, index) {
                  final page = _pages[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 34),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 190,
                          height: 190,
                          decoration: BoxDecoration(
                            gradient: brandGradient,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: primaryBlue.withValues(alpha: 0.25),
                                blurRadius: 30,
                                offset: const Offset(0, 14),
                              ),
                            ],
                          ),
                          child: Icon(
                            page.icon,
                            size: 84,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 44),
                        Text(
                          page.title,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 23,
                            fontWeight: FontWeight.bold,
                            color: darkText,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          page.description,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.7,
                            color: secondaryText,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_pages.length, (i) {
                final isActive = i == _page;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: isActive ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: isActive
                        ? primaryBlue
                        : primaryBlue.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 26, 28, 20),
              child: SizedBox(
                width: double.infinity,
                height: 56,
                child: GradientButton(
                  label: isLast ? 'دەستپێبکە' : 'دواتر',
                  onPressed: _next,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// LOGIN / SIGN IN - FIREBASE
// ============================================================

// ============================================================
// GOOGLE SIGN-IN
// ============================================================

class BlockedAccountException implements Exception {
  const BlockedAccountException();
}

/// ئەنجامی چوونەژوورەوە بە Google.
/// - [isFirstTime]: یەکەم جارە ئەم هەژمارە دروست دەبێت.
/// - [needsPasswordSetup]: پێویستە داوای دانانی وشەی نهێنی بکرێت.
class GoogleSignInOutcome {
  final UserCredential credential;
  final bool isFirstTime;
  final bool needsPasswordSetup;

  const GoogleSignInOutcome({
    required this.credential,
    required this.isFirstTime,
    required this.needsPasswordSetup,
  });
}

/// "بەردەوام بوون بە Google" — یەک فەنکشن بۆ چوونەژوورەوە و
/// دروستکردنی هەژمار:
///  • یەکەم جار → هەژمار دروست دەکات، پاشان داوای وشەی نهێنی.
///  • جاری دووەم و زیاتر → راستەوخۆ دەچێتە ژوورەوە.
/// ئەگەر هەژمارەکە لەلایەن ئەدمینەوە بلۆککرابوو، دەرچوونی
/// خۆکارانە دەکات و BlockedAccountException دەنێرێت.
Future<GoogleSignInOutcome> signInWithGoogle() async {
  final googleSignIn = GoogleSignIn.instance;
  // Web Client ID ـی پرۆژەکە (لە Firebase Console → Authentication
  // → Sign-in method → Google → Web SDK configuration). ئەم ID ـە
  // پێویستە بۆ ئەوەی idToken ـی دروست بگەڕێندرێتەوە، ئەگینا
  // Firebase ناتوانێت هەژمارەکە پشتڕاست بکاتەوە.
  await googleSignIn.initialize(
    serverClientId:
        '890683591352-fihsvap7uelnt4oqv30eb9k8oqc49nkg.apps.googleusercontent.com',
  );

  final GoogleSignInAccount account = await googleSignIn.authenticate();
  final GoogleSignInAuthentication auth = account.authentication;

  final credential = GoogleAuthProvider.credential(idToken: auth.idToken);

  final userCredential =
      await FirebaseAuth.instance.signInWithCredential(credential);
  final user = userCredential.user;

  if (user == null) {
    throw Exception('Google sign-in returned no user');
  }

  final docRef =
      FirebaseFirestore.instance.collection('users').doc(user.uid);
  final doc = await docRef.get();

  if (doc.data()?['blocked'] as bool? ?? false) {
    await FirebaseAuth.instance.signOut();
    throw const BlockedAccountException();
  }

  final isFirstTime =
      (userCredential.additionalUserInfo?.isNewUser ?? false) ||
          !doc.exists;

  // ئەگەر پێشتر وشەی نهێنی هەبێت (provider ی password)، پێویست بە
  // داواکردن نییە.
  final hasPassword =
      user.providerData.any((p) => p.providerId == 'password');

  // ئەگەر جارێکی پێشوو ئەپەکە داخرا پێش دانانی وشەی نهێنی،
  // ئەم نیشانەیە (needsPasswordSetup) دووبارە داوای دەکاتەوە.
  final pending = doc.data()?['needsPasswordSetup'] as bool? ?? false;
  final needsPasswordSetup = !hasPassword && (isFirstTime || pending);

  if (!doc.exists) {
    await docRef.set({
      'uid': user.uid,
      'name': user.displayName ?? '',
      'email': user.email ?? '',
      'photoUrl': user.photoURL,
      'needsPasswordSetup': needsPasswordSetup,
      'createdAt': FieldValue.serverTimestamp(),
    });
  } else {
    await docRef.set({
      'name': user.displayName ?? doc.data()?['name'],
      'photoUrl': user.photoURL ?? doc.data()?['photoUrl'],
    }, SetOptions(merge: true));
  }

  return GoogleSignInOutcome(
    credential: userCredential,
    isFirstTime: isFirstTime,
    needsPasswordSetup: needsPasswordSetup,
  );
}

/// یەک دوگمەی هاوبەش بۆ LoginScreen و SignUpScreen.
class GoogleContinueButton extends StatefulWidget {
  const GoogleContinueButton({super.key});

  @override
  State<GoogleContinueButton> createState() => _GoogleContinueButtonState();
}

class _GoogleContinueButtonState extends State<GoogleContinueButton> {
  bool isLoading = false;

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
  }

  Future<void> _continueWithGoogle() async {
    setState(() => isLoading = true);

    try {
      final outcome = await signInWithGoogle();

      if (!mounted) return;
      setState(() => isLoading = false);

      _showMessage(
        outcome.isFirstTime
            ? 'ئەکاونتەکەت بە سەرکەوتوویی دروستکرا. 🎉'
            : 'بەخێربێیتەوە. 👋',
      );

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => outcome.needsPasswordSetup
              ? const SetPasswordScreen()
              : const HomeScreen(),
        ),
        (route) => false,
      );
    } on BlockedAccountException {
      if (!mounted) return;
      setState(() => isLoading = false);
      _showMessage('هەژمارەکەت ڕاگیراوە. تکایە پەیوەندی بە پشتگیری بکە.');
    } catch (e) {
      if (!mounted) return;
      setState(() => isLoading = false);
      // بەکارهێنەر خۆی پاشگەزبووەوە → پەیامی هەڵە پیشان نادەین.
      final message = e.toString();
      if (message.contains('canceled') || message.contains('cancelled')) {
        return;
      }
      _showMessage('نەتوانرا بە Google بچیتە ژوورەوە. دووبارە هەوڵبدەرەوە.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: OutlinedButton.icon(
        onPressed: isLoading ? null : _continueWithGoogle,
        icon: isLoading
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: darkText,
                ),
              )
            : const Text(
                'G',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF4285F4),
                ),
              ),
        label: Text(
          'بەردەوام بوون بە Google',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: darkText,
          ),
        ),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: cardBorderColor),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool obscurePassword = true;
  bool isLoading = false;

  // ------------------------------------------------------------
  // SHOW MESSAGE
  // ------------------------------------------------------------

  void showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
  }

  // ------------------------------------------------------------
  // LOGIN WITH FIREBASE
  // ------------------------------------------------------------

  Future<void> login() async {
    final email = emailController.text.trim();
    final password = passwordController.text;

    // Email validation
    if (email.isEmpty) {
      showMessage('تکایە ئیمەیڵ بنڤیسە.');
      return;
    }

    // Password validation
    if (password.isEmpty) {
      showMessage('تکایە وشەی نهێنی بنڤیسە.');
      return;
    }

    setState(() {
      isLoading = true;
    });

    try {
      // --------------------------------------------------------
      // FIREBASE SIGN IN
      // --------------------------------------------------------

      final userCredential =
          await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      // --------------------------------------------------------
      // USER INFORMATION
      // --------------------------------------------------------

      final user = userCredential.user;

      if (user != null) {
        print('LOGIN SUCCESS');
        print('USER ID: ${user.uid}');
        print('EMAIL: ${user.email}');

        // پشکنین ئایا ئەم هەژمارە لەلایەن ئەدمینەوە بلۆککراوە
        final userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();
        final blocked = userDoc.data()?['blocked'] as bool? ?? false;

        if (blocked) {
          await FirebaseAuth.instance.signOut();
          if (!mounted) return;
          setState(() => isLoading = false);
          showMessage(
            'هەژمارەکەت ڕاگیراوە. تکایە پەیوەندی بە پشتگیری بکە.',
          );
          return;
        }
      }

      if (!mounted) return;

      setState(() {
        isLoading = false;
      });

      showMessage('بە سەرکەوتوویی چوویتە ژوورەوە. 🎉');

      // --------------------------------------------------------
      // GO TO HOME
      // --------------------------------------------------------

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => const HomeScreen(),
        ),
        (route) => false,
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;

      setState(() {
        isLoading = false;
      });

      String message;

      switch (e.code) {
        case 'invalid-email':
          message = 'ئیمەیڵەکە دروست نییە.';
          break;

        case 'user-not-found':
          message = 'هیچ هەژمارێک بەو ئیمەیڵە نەدۆزرایەوە.';
          break;

        case 'wrong-password':
          message = 'وشەی نهێنی هەڵەیە.';
          break;

        case 'invalid-credential':
          message = 'ئیمەیڵ یان وشەی نهێنی هەڵەیە.';
          break;

        case 'user-disabled':
          message = 'ئەم هەژمارە ناچالاک کراوە.';
          break;

        case 'too-many-requests':
          message =
              'هەوڵی زۆر دراوە. تکایە کەمێک چاوەڕێ بکە و دووبارە هەوڵ بدە.';
          break;

        case 'network-request-failed':
          message =
              'کێشەی ئینتەرنێت هەیە. تکایە پەیوەندی ئینتەرنێتەکەت بپشکنە.';
          break;

        default:
          message =
              'نەتوانرا بچیتە ژوورەوە. تکایە ئیمەیڵ و وشەی نهێنی بپشکنە.';
      }

      showMessage(message);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        isLoading = false;
      });

      showMessage('هەڵەیەک ڕوویدا. تکایە دووبارە هەوڵ بدە.');
    }
  }

  // ------------------------------------------------------------
  // FORGOT PASSWORD
  // ------------------------------------------------------------

  Future<void> forgotPassword() async {
    final email = emailController.text.trim();

    if (email.isEmpty) {
      showMessage(
        'سەرەتا ئیمەیڵەکەت بنووسە، پاشان کرتە لە وشەی نهێنیت لەبیرکردووە بکە.',
      );
      return;
    }

    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(
        email: email,
      );

      if (!mounted) return;

      showMessage(
        'لینکی گۆڕینی وشەی نهێنی بۆ ئیمەیڵەکەت نێردرا. 📧',
      );
    } on FirebaseAuthException catch (e) {
      String message;

      switch (e.code) {
        case 'invalid-email':
          message = 'ئیمەیڵەکە دروست نییە.';
          break;

        case 'user-not-found':
          message = 'هیچ هەژمارێک بەو ئیمەیڵە نەدۆزرایەوە.';
          break;

        case 'network-request-failed':
          message =
              'کێشەی ئینتەرنێت هەیە. تکایە دووبارە هەوڵ بدە.';
          break;

        default:
          message =
              'نەتوانرا ئیمەیڵی گۆڕینی وشەی نهێنی بنێردرێت.';
      }

      showMessage(message);
    } catch (e) {
      showMessage(
        'هەڵەیەک ڕوویدا. تکایە دووبارە هەوڵ بدە.',
      );
    }
  }

  // ------------------------------------------------------------
  // DISPOSE
  // ------------------------------------------------------------

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------
  // BUILD
  // ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,

      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: Text(
          'چوونەژوورەوە',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: darkText,
          ),
        ),
      ),

      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: 500,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [

                  // ------------------------------------------------
                  // LOGO
                  // ------------------------------------------------

                  const AppLogo(size: 90),

                  const SizedBox(height: 20),

                  Text(
                    'بەخێربێیت بۆ ZNAR Academy',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: darkText,
                    ),
                  ),

                  const SizedBox(height: 8),

                  Text(
                    'بۆ بەردەوامبوون بچۆ ژوورەوە',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      color: secondaryText,
                    ),
                  ),

                  const SizedBox(height: 35),

                  // ------------------------------------------------
                  // EMAIL
                  // ------------------------------------------------

                  Text(
                    'ئیمەیڵ',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: darkText,
                    ),
                  ),

                  const SizedBox(height: 8),

                  TextField(
                    controller: emailController,
                    keyboardType: TextInputType.emailAddress,
                    textDirection: TextDirection.ltr,
                    decoration: InputDecoration(
                      hintText: 'example@email.com',
                      prefixIcon: const Icon(
                        Icons.email_outlined,
                      ),
                      filled: true,
                      fillColor: cardSurfaceColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(
                          color: cardBorderColor,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(
                          color: Color(0xFF2563EB),
                          width: 2,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  // ------------------------------------------------
                  // PASSWORD
                  // ------------------------------------------------

                  Text(
                    'وشەی نهێنی',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: darkText,
                    ),
                  ),

                  const SizedBox(height: 8),

                  TextField(
                    controller: passwordController,
                    obscureText: obscurePassword,
                    decoration: InputDecoration(
                      hintText: 'وشەی نهێنی',
                      prefixIcon: const Icon(
                        Icons.lock_outline,
                      ),
                      suffixIcon: IconButton(
                        onPressed: () {
                          setState(() {
                            obscurePassword = !obscurePassword;
                          });
                        },
                        icon: Icon(
                          obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                      filled: true,
                      fillColor: cardSurfaceColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(
                          color: cardBorderColor,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(
                          color: Color(0xFF2563EB),
                          width: 2,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // ------------------------------------------------
                  // FORGOT PASSWORD
                  // ------------------------------------------------

                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: forgotPassword,
                      child: const Text(
                        'وشەی نهێنیت لەبیرکردووە؟',
                        style: TextStyle(
                          color: Color(0xFF2563EB),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 15),

                  // ------------------------------------------------
                  // LOGIN BUTTON
                  // ------------------------------------------------

                  GradientButton(
                    label: 'چوونەژوورەوە',
                    isLoading: isLoading,
                    onPressed: isLoading ? null : login,
                  ),

                  const SizedBox(height: 25),

                  // ------------------------------------------------
                  // DIVIDER
                  // ------------------------------------------------

                  Row(
                    children: [
                      Expanded(
                        child: Divider(
                          color: cardBorderColor,
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        child: Text(
                          'یان',
                          style: TextStyle(
                            color: secondaryText,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Divider(
                          color: cardBorderColor,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),

                  // ------------------------------------------------
                  // GOOGLE SIGN-IN
                  // ------------------------------------------------

                  const GoogleContinueButton(),

                  const SizedBox(height: 20),

                  // ------------------------------------------------
                  // CREATE ACCOUNT
                  // ------------------------------------------------

                  OutlinedButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const SignUpScreen(),
                        ),
                      );
                    },
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(
                        double.infinity,
                        54,
                      ),
                      side: const BorderSide(
                        color: Color(0xFF2563EB),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: const Text(
                      'دروستکردنی ئەکاونت',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF2563EB),
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  const Text(
                    'ZNAR Academy',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: Color(0xFF94A3B8),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}


// ============================================================
// SIGN UP SCREEN
// ============================================================

// ============================================================
// SET PASSWORD (بۆ هەژمارە نوێیەکانی Google — دەرفەت دەدات
// وشەی نهێنی زیاد بکەن، تاکو دواتریش بتوانن بە ئیمەیل/وشەی
// نهێنی بچنە ژوورەوە بەبێ Google).
// ============================================================

class SetPasswordScreen extends StatefulWidget {
  const SetPasswordScreen({super.key});

  @override
  State<SetPasswordScreen> createState() => _SetPasswordScreenState();
}

class _SetPasswordScreenState extends State<SetPasswordScreen> {
  final passwordController = TextEditingController();
  bool obscurePassword = true;
  bool isLoading = false;

  bool hasSymbol(String value) {
    return RegExp(
      r'''[!@#$%^&*(),.?":{}|<>_\-\\/\[\]+='`]''',
    ).hasMatch(value);
  }

  bool hasUppercase(String value) {
    return RegExp(r'[A-Z]').hasMatch(value);
  }

  void showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  /// نیشانەی needsPasswordSetup لادەبات، تاکو دووبارە داوا نەکرێتەوە.
  Future<void> _markSetupDone() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .set({'needsPasswordSetup': false}, SetOptions(merge: true));
    } catch (_) {
      // گرنگ نییە — تەنها نیشانەیەکە.
    }
  }

  Future<void> goHome() async {
    await _markSetupDone();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (route) => false,
    );
  }

  Future<void> setPassword() async {
    final password = passwordController.text;

    if (password.length < 8 ||
        !hasSymbol(password) ||
        !hasUppercase(password)) {
      showMessage(
        'وشەی نهێنی دەبێت لانیکەم 8 پیت بێت، پیتێکی گەورە و هێمایەکی تایبەتی تێدا بێت.',
      );
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.email == null) {
      goHome();
      return;
    }

    setState(() => isLoading = true);
    try {
      final credential = EmailAuthProvider.credential(
        email: user.email!,
        password: password,
      );
      await user.linkWithCredential(credential);

      if (!mounted) return;
      showMessage('وشەی نهێنی زیادکرا بە سەرکەوتوویی. 🎉');
      goHome();
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() => isLoading = false);
      if (e.code == 'provider-already-linked' ||
          e.code == 'credential-already-in-use') {
        showMessage('ئەم هەژمارە پێشتر وشەی نهێنی هەیە.');
        goHome();
        return;
      }
      showMessage('نەتوانرا وشەی نهێنی زیاد بکرێت. دووبارە هەوڵبدەرەوە.');
    } catch (e) {
      if (!mounted) return;
      setState(() => isLoading = false);
      showMessage('هەڵە: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = FirebaseAuth.instance.currentUser?.email ?? '';

    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 20),
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: primaryBlue.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.lock_outline_rounded,
                  size: 34,
                  color: primaryBlue,
                ),
              ),
              const SizedBox(height: 22),
              Text(
                'وشەی نهێنی بۆ هەژمارەکەت دابنێ',
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.bold,
                  color: darkText,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'هەژمارەکەت ($email) بە Google دروستکرا. ئارەزوومەندانە، '
                'وشەی نهێنی دابنێ تاکو دواتریش بتوانیت بەبێ Google '
                'بچیتە ژوورەوە.',
                style: TextStyle(color: secondaryText, height: 1.5),
              ),
              const SizedBox(height: 28),
              TextField(
                controller: passwordController,
                obscureText: obscurePassword,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) {
                  if (!isLoading) setPassword();
                },
                decoration: InputDecoration(
                  hintText: 'لانیکەم 8 پیت + هێمایەک',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    onPressed: () {
                      setState(() => obscurePassword = !obscurePassword);
                    },
                    icon: Icon(
                      obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                  filled: true,
                  fillColor: cardSurfaceColor,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: GradientButton(
                  label: 'دانانی وشەی نهێنی',
                  isLoading: isLoading,
                  onPressed: isLoading ? null : setPassword,
                ),
              ),
              const SizedBox(height: 14),
              Center(
                child: TextButton(
                  onPressed: isLoading ? null : goHome,
                  child: const Text('دواتر / لابردنی ئەم هەنگاوە'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  // ----------------------------------------------------------
  // CONTROLLERS
  // ----------------------------------------------------------

  final TextEditingController nameController =
      TextEditingController();

  final TextEditingController emailController =
      TextEditingController();

  final TextEditingController passwordController =
      TextEditingController();

  // ----------------------------------------------------------
  // VARIABLES
  // ----------------------------------------------------------

  bool obscurePassword = true;
  bool acceptedTerms = false;
  bool isLoading = false;

  // ----------------------------------------------------------
  // PASSWORD SYMBOL CHECK
  // ----------------------------------------------------------

  bool hasSymbol(String value) {
    return RegExp(
      r'''[!@#$%^&*(),.?":{}|<>_\-\\/\[\]+='`]''',
    ).hasMatch(value);
  }

  bool hasUppercase(String value) {
    return RegExp(r'[A-Z]').hasMatch(value);
  }

  // ----------------------------------------------------------
  // SHOW MESSAGE
  // ----------------------------------------------------------

  void showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  // ----------------------------------------------------------
  // INPUT DECORATION
  // ----------------------------------------------------------

  InputDecoration inputDecoration({
    required String hint,
    required IconData icon,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return InputDecoration(
      hintText: hint,
      prefixIcon: Icon(icon),
      filled: true,
      fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(
          color: colorScheme.outline.withValues(alpha: 0.15),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(
          color: colorScheme.primary,
          width: 1.5,
        ),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 17,
      ),
    );
  }

  // ----------------------------------------------------------
  // LABEL
  // ----------------------------------------------------------

  Widget label(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  // ==========================================================
  // CREATE ACCOUNT
  // ==========================================================

  Future<void> createAccount() async {
    final name = nameController.text.trim();
    final email = emailController.text.trim();
    final password = passwordController.text;

    // --------------------------------------------------------
    // NAME VALIDATION
    // --------------------------------------------------------

    if (name.isEmpty) {
      showMessage('تکایە ناڤێ خۆ بنڤیسە.');
      return;
    }

    // --------------------------------------------------------
    // EMAIL VALIDATION
    // --------------------------------------------------------

    if (email.isEmpty) {
      showMessage('تکایە ئیمەیڵ بنڤیسە.');
      return;
    }

    // --------------------------------------------------------
    // SIMPLE EMAIL CHECK
    // --------------------------------------------------------

    if (!RegExp(
      r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
    ).hasMatch(email)) {
      showMessage('تکایە ئیمەیڵێکی دروست بنڤیسە.');
      return;
    }

    // --------------------------------------------------------
    // PASSWORD LENGTH
    // --------------------------------------------------------

    if (password.length < 8) {
      showMessage(
        'وشەی نهێنی دەبێت لانیکەم 8 پیت بێت.',
      );
      return;
    }

    // --------------------------------------------------------
    // PASSWORD SYMBOL
    // --------------------------------------------------------

    if (!hasSymbol(password)) {
      showMessage(
        'وشەی نهێنی دەبێت هێمایەکی تایبەتی هەبێت، وەک @ یان !',
      );
      return;
    }

    // --------------------------------------------------------
    // PASSWORD UPPERCASE
    // --------------------------------------------------------

    if (!hasUppercase(password)) {
      showMessage(
        'وشەی نهێنی دەبێت لانیکەم یەک پیتی گەورە (A-Z) هەبێت.',
      );
      return;
    }

    // --------------------------------------------------------
    // TERMS
    // --------------------------------------------------------

    if (!acceptedTerms) {
      showMessage(
        'تکایە مەرج و یاساکان قبوڵ بکە.',
      );
      return;
    }

    // --------------------------------------------------------
    // START LOADING
    // --------------------------------------------------------

    setState(() {
      isLoading = true;
    });

    try {
      // ------------------------------------------------------
      // SIGN UP STARTED
      // ------------------------------------------------------

      print('SIGN UP STARTED');

      // ------------------------------------------------------
      // CREATE USER IN FIREBASE AUTHENTICATION
      // ------------------------------------------------------

      final UserCredential userCredential =
          await FirebaseAuth.instance
              .createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      // ------------------------------------------------------
      // USER CREATED
      // ------------------------------------------------------

      print('FIREBASE USER CREATED');
      print(
        'USER ID: ${userCredential.user?.uid}',
      );
      print(
        'EMAIL: ${userCredential.user?.email}',
      );

      // ------------------------------------------------------
      // SAVE USER NAME IN FIREBASE AUTH
      // ------------------------------------------------------

      await userCredential.user?.updateDisplayName(name);

      // ------------------------------------------------------
      // SAVE USER DATA IN CLOUD FIRESTORE
      // ------------------------------------------------------
      // ئەمە ئەو بەشەیە کە داتای بەکارهێنەر لە Firestore
      // خەزن دەکات، چونکە Firebase Auth تەنها uid/email/name
      // هەڵدەگرێت و داتابەیسێکی تر نییە.

      await FirebaseFirestore.instance
          .collection('users')
          .doc(userCredential.user?.uid)
          .set({
        'uid': userCredential.user?.uid,
        'name': name,
        'email': email,
        'createdAt': FieldValue.serverTimestamp(),
      });

      print('USER DATA SAVED IN FIRESTORE');

      // ------------------------------------------------------
      // REFRESH USER
      // ------------------------------------------------------

      await userCredential.user?.reload();

      // ------------------------------------------------------
      // CHECK WIDGET
      // ------------------------------------------------------

      if (!mounted) return;

      // ------------------------------------------------------
      // SUCCESS MESSAGE
      // ------------------------------------------------------

      showMessage(
        'هەژمارەکەت بە سەرکەوتوویی دروست کرا. 🎉',
      );

      // ------------------------------------------------------
      // GO TO HOME SCREEN
      // ------------------------------------------------------

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => const HomeScreen(),
        ),
        (route) => false,
      );
    }

    // ----------------------------------------------------------
    // FIREBASE ERROR
    // ----------------------------------------------------------

    on FirebaseAuthException catch (e) {
      String message;

      switch (e.code) {
        case 'email-already-in-use':
          message =
              'ئەم ئیمەیڵە پێشتر بەکارهاتووە.';
          break;

        case 'invalid-email':
          message =
              'ئیمەیڵەکە دروست نییە.';
          break;

        case 'weak-password':
          message =
              'وشەی نهێنی لاوازە.';
          break;

        case 'operation-not-allowed':
          message =
              'Email/Password لە Firebase چالاک نەکراوە.';
          break;

        case 'network-request-failed':
          message =
              'کێشەی ئینتەرنێت هەیە. تکایە دووبارە هەوڵ بدە.';
          break;

        case 'too-many-requests':
          message =
              'هەوڵەکان زۆر بوون. تکایە کەمێک چاوەڕێ بکە.';
          break;

        default:
          message =
              'هەڵەیەک لە Firebase ڕوویدا. تکایە دووبارە هەوڵ بدە.';
      }

      // --------------------------------------------------------
      // PRINT ERROR FOR DEBUGGING
      // --------------------------------------------------------

      print(
        'FIREBASE ERROR CODE: ${e.code}',
      );

      print(
        'FIREBASE ERROR MESSAGE: ${e.message}',
      );

      if (!mounted) return;

      showMessage(message);
    }

    // ----------------------------------------------------------
    // OTHER ERROR
    // ----------------------------------------------------------

    catch (e) {
      print('SIGN UP ERROR: $e');

      if (!mounted) return;

      showMessage(
        'هەڵەیەک ڕوویدا. تکایە دووبارە هەوڵ بدە.',
      );
    }

    // ----------------------------------------------------------
    // STOP LOADING
    // ----------------------------------------------------------

    finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  // ==========================================================
  // DISPOSE
  // ==========================================================

  @override
  void dispose() {
    nameController.dispose();
    emailController.dispose();
    passwordController.dispose();

    super.dispose();
  }

  // ==========================================================
  // BUILD
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'دروستکردنی ئەکاونت',
        ),
        centerTitle: true,
      ),

      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            24,
            20,
            24,
            30,
          ),

          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,

            children: [
              // ------------------------------------------------
              // HEADER
              // ------------------------------------------------

              Center(
                child: const AppLogo(size: 90),
              ),

              const SizedBox(height: 20),

              Center(
                child: Text(
                  'بەخێربێیت بۆ ZNAR Academy 👋',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),

              const SizedBox(height: 8),

              Center(
                child: Text(
                  'هەژمارەکەت دروست بکە بۆ دەستپێکردن.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),

              const SizedBox(height: 30),

              // ------------------------------------------------
              // NAME
              // ------------------------------------------------

              label('ناڤ'),

              const SizedBox(height: 8),

              TextField(
                controller: nameController,
                textInputAction:
                    TextInputAction.next,
                decoration: inputDecoration(
                  hint: 'ناڤێ تە',
                  icon: Icons.person_outline,
                ),
              ),

              const SizedBox(height: 18),

              // ------------------------------------------------
              // EMAIL
              // ------------------------------------------------

              label('ئیمەیڵ'),

              const SizedBox(height: 8),

              TextField(
                controller: emailController,
                keyboardType:
                    TextInputType.emailAddress,
                textInputAction:
                    TextInputAction.next,
                autocorrect: false,
                decoration: inputDecoration(
                  hint: 'example@email.com',
                  icon: Icons.email_outlined,
                ),
              ),

              const SizedBox(height: 18),

              // ------------------------------------------------
              // PASSWORD
              // ------------------------------------------------

              label('وشەی نهێنی'),

              const SizedBox(height: 8),

              TextField(
                controller: passwordController,
                obscureText: obscurePassword,
                textInputAction:
                    TextInputAction.done,

                onSubmitted: (_) {
                  if (!isLoading) {
                    createAccount();
                  }
                },

                decoration:
                    inputDecoration(
                  hint: 'لانیکەم 8 پیت + هێمایەک',
                  icon: Icons.lock_outline,
                ).copyWith(
                  suffixIcon: IconButton(
                    onPressed: () {
                      setState(() {
                        obscurePassword =
                            !obscurePassword;
                      });
                    },
                    icon: Icon(
                      obscurePassword
                          ? Icons
                              .visibility_outlined
                          : Icons
                              .visibility_off_outlined,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 10),

              // ------------------------------------------------
              // PASSWORD INFO
              // ------------------------------------------------

              Row(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 17,
                    color:
                        colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      'وشەی نهێنی دەبێت لانیکەم 8 پیت بێت و هێمایەکی تایبەتی تێدا بێت.',
                      style: TextStyle(
                        fontSize: 13,
                        color:
                            colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 14),

              // ------------------------------------------------
              // TERMS
              // ------------------------------------------------

              CheckboxListTile(
                value: acceptedTerms,
                contentPadding:
                    EdgeInsets.zero,

                controlAffinity:
                    ListTileControlAffinity.leading,

                onChanged: isLoading
                    ? null
                    : (value) {
                        setState(() {
                          acceptedTerms =
                              value ?? false;
                        });
                      },

                title: const Text(
                  'مەرج و یاساکان قبوڵ دەکەم',
                  style: TextStyle(
                    fontSize: 14,
                  ),
                ),
              ),

              const SizedBox(height: 15),

              // ------------------------------------------------
              // CREATE ACCOUNT BUTTON
              // ------------------------------------------------

              GradientButton(
                label: 'دروستکردنی ئەکاونت',
                isLoading: isLoading,
                onPressed: isLoading ? null : createAccount,
              ),

              const SizedBox(height: 20),

              // ------------------------------------------------
              // OR DIVIDER
              // ------------------------------------------------

              Row(
                children: [
                  Expanded(child: Divider(color: cardBorderColor)),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text('یان'),
                  ),
                  Expanded(child: Divider(color: cardBorderColor)),
                ],
              ),

              const SizedBox(height: 20),

              // ------------------------------------------------
              // GOOGLE SIGN-UP
              // ------------------------------------------------

              const GoogleContinueButton(),

              const SizedBox(height: 20),

              // ------------------------------------------------
              // LOGIN LINK
              // ------------------------------------------------

              Center(
                child: TextButton(
                  onPressed: isLoading
                      ? null
                      : () {
                          Navigator.pop(context);
                        },
                  child: const Text(
                    'پێشتر ئەکاونتت هەیە؟ بچۆ ژوورەوە',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


// ============================================================
// FORGOT PASSWORD
// ============================================================

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final emailController = TextEditingController();
  bool isLoading = false;

  @override
  void dispose() {
    emailController.dispose();
    super.dispose();
  }

  Future<void> _sendLink() async {
    final email = emailController.text.trim();

    if (email.isEmpty || !email.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تکایە ئیمەیڵێکی دروست بنووسە.')),
      );
      return;
    }

    setState(() => isLoading = true);
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'ئەگەر ئەم ئیمەیڵە هەژمارێکی هەبێت، لینکی گۆڕینی وشەی نهێنی نێردرا ✅',
          ),
        ),
      );
      Navigator.pop(context);
    } on FirebaseAuthException catch (e) {
      String message = 'هەڵەیەک ڕوویدا. تکایە دووبارە هەوڵ بدە.';
      if (e.code == 'invalid-email') {
        message = 'شێوازی ئیمەیڵەکە دروست نییە.';
      } else if (e.code == 'too-many-requests') {
        message = 'هەوڵی زۆر — تکایە دواتر هەوڵبدەرەوە.';
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('وشەی نهێنی'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 30),

            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    primaryBlue.withValues(alpha: 0.12),
                    secondaryPurple.withValues(alpha: 0.12),
                  ],
                ),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.lock_reset_outlined,
                size: 40,
                color: primaryBlue,
              ),
            ),

            const SizedBox(height: 22),

            const Text(
              'وشەی نهێنیت لەبیرکردووە؟',
              style: TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 10),

            Text(
              'ئیمەیڵەکەت بنووسە بۆ ناردنی لینکی گۆڕینی وشەی نهێنی.',
              style: TextStyle(
                color: secondaryText,
                fontSize: 15,
              ),
            ),

            const SizedBox(height: 30),

            TextField(
              controller: emailController,
              keyboardType: TextInputType.emailAddress,
              textDirection: TextDirection.ltr,
              decoration: _inputDecoration(
                hint: 'example@email.com',
                icon: Icons.email_outlined,
              ),
            ),

            const SizedBox(height: 20),

            GradientButton(
              label: 'ناردنی لینک',
              isLoading: isLoading,
              onPressed: isLoading ? null : _sendLink,
              height: 55,
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// PRODUCT MODEL
// ============================================================

class Product {
  final String id;
  final String title;
  final String category;
  final String description;
  final String author;
  final double rating;
  final int reviews;
  final double oldPrice;
  final double price;
  final IconData icon;
  final Color color;
  final String? pdfAsset;
  final String? pdfUrl;
  final String? coverImageUrl;

  /// ڤیدیۆیەکی کورتی پرێڤیو (ئارەزوومەندانە) — بۆ پیشاندانی
  /// ئەنیمەیشنی تێمپلەیتەکانی پاوەرپۆینت پێش کڕین، چونکە PDF
  /// ئەنیمەیشن پیشان نادات.
  final String? previewVideoUrl;

  /// فایلی دۆکیومێنتی ڕاستەقینە (وەک .docx, .pptx, .xlsx, .zip)
  /// کە دوای کڕین بەکارهێنەر دەتوانێت دایبگرێت و دەستکاری بکات —
  /// جیاوازە لە pdfUrl کە تەنها بۆ بینینە.
  final String? documentUrl;
  final String? documentFileName;

  final DateTime? createdAt;

  /// زمانی ناوەڕۆکی بەرهەمەکە (کوردی/عەرەبی/ئینگلیزی) — جیاوازە
  /// لە زمانی ڕووکاری ئەپەکە. بەکاردێت بۆ فلتەرکردن لە گەڕان.
  final String language;

  /// ئایا بەرهەمەکە بەردەستە بۆ بەکارهێنەران (چالاکە). ئەگەر
  /// false بێت، لە گەڕان/ماڵەوە/لیستی بەرهەمەکان دەشاردرێتەوە،
  /// بەبێ ئەوەی بسڕدرێتەوە — بەکارهێنەرانی کە پێشتر کڕیویانە
  /// یان دڵخوازیان کردووە هێشتا دەیبینن.
  final bool isActive;

  /// ئایا ئەم بەرهەمە لە پەڕەی سەرەکی (Home — بەشەکانی نوێ/
  /// باو/داشکاندن) دەردەکەوێت؟ ئەگەر false بێت، تەنها لەناو
  /// پەڕەی کەتەگۆرییەکەی و گەڕاندا دەردەکەوێت، وەک خۆی
  /// کڕدراو دەمێنێتەوە.
  final bool showOnHome;

  const Product({
    required this.id,
    required this.title,
    required this.category,
    required this.description,
    required this.author,
    required this.rating,
    required this.reviews,
    required this.oldPrice,
    required this.price,
    required this.icon,
    required this.color,
    this.pdfAsset,
    this.pdfUrl,
    this.coverImageUrl,
    this.previewVideoUrl,
    this.documentUrl,
    this.documentFileName,
    this.createdAt,
    this.language = 'کوردی',
    this.isActive = true,
    this.showOnHome = true,
  });

  /// بەرهەمێک "داشکاندن" ـی هەیە ئەگەر نرخی کۆن لە نرخی ئێستا
  /// بەرزتر بێت.
  bool get isOffer => oldPrice > price;

  /// ڕێژەی داشکاندن بە سەدا (بۆ پیشاندان لە UI).
  int get discountPercent {
    if (!isOffer || oldPrice == 0) return 0;
    return (((oldPrice - price) / oldPrice) * 100).round();
  }

  /// بەرهەمێکی بەخۆڕایی — پێویستی بە کڕین نییە، هەر
  /// بەکارهێنەرێک دەتوانێت ڕاستەوخۆ بیکاتەوە.
  bool get isFree => price <= 0;

  /// دروستکردنی Product لە بەڵگەنامەیەکی Firestore
  /// (⚠️ پێویستە build بکرێت بە: flutter build --no-tree-shake-icons
  /// چونکە ئایکۆنەکان بە شێوەی داینامیکی لە codePoint دروست دەبن)
  factory Product.fromMap(String id, Map<String, dynamic> map) {
    return Product(
      id: id,
      title: map['title'] as String? ?? '',
      category: map['category'] as String? ?? '',
      description: map['description'] as String? ?? '',
      author: map['author'] as String? ?? '',
      rating: (map['rating'] as num?)?.toDouble() ?? 0,
      reviews: (map['reviews'] as num?)?.toInt() ?? 0,
      oldPrice: (map['oldPrice'] as num?)?.toDouble() ?? 0,
      price: (map['price'] as num?)?.toDouble() ?? 0,
      icon: IconData(
        // ignore: non_const_argument_for_const_parameter
        (map['iconCodePoint'] as num?)?.toInt() ??
            Icons.menu_book_rounded.codePoint,
        fontFamily: 'MaterialIcons',
      ),
      color: Color(
        (map['colorValue'] as num?)?.toInt() ?? primaryBlue.toARGB32(),
      ),
      pdfAsset: map['pdfAsset'] as String?,
      pdfUrl: map['pdfUrl'] as String?,
      coverImageUrl: map['coverImageUrl'] as String?,
      previewVideoUrl: map['previewVideoUrl'] as String?,
      documentUrl: map['documentUrl'] as String?,
      documentFileName: map['documentFileName'] as String?,
      createdAt: (map['createdAt'] is Timestamp)
          ? (map['createdAt'] as Timestamp).toDate()
          : null,
      language: map['language'] as String? ?? 'کوردی',
      isActive: map['isActive'] as bool? ?? true,
      showOnHome: map['showOnHome'] as bool? ?? true,
    );
  }

  /// گۆڕینی Product بۆ Map تاکو لە Firestore خەزن بکرێت
  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'category': category,
      'description': description,
      'author': author,
      'rating': rating,
      'reviews': reviews,
      'oldPrice': oldPrice,
      'price': price,
      'iconCodePoint': icon.codePoint,
      'colorValue': color.toARGB32(),
      if (pdfAsset != null) 'pdfAsset': pdfAsset,
      if (pdfUrl != null) 'pdfUrl': pdfUrl,
      if (coverImageUrl != null) 'coverImageUrl': coverImageUrl,
      if (previewVideoUrl != null) 'previewVideoUrl': previewVideoUrl,
      if (documentUrl != null) 'documentUrl': documentUrl,
      if (documentFileName != null) 'documentFileName': documentFileName,
      // ئەگەر createdAt نەبوو، کاتی ئێستا بەکاردێت (بۆ seed
      // data)؛ ئەمە دەبێتە Firestore Timestamp خۆکارانە.
      'createdAt': createdAt != null
          ? Timestamp.fromDate(createdAt!)
          : FieldValue.serverTimestamp(),
      'language': language,
      'isActive': isActive,
      'showOnHome': showOnHome,
    };
  }
}

/// زمانە بەردەستەکان بۆ ناوەڕۆکی بەرهەم — بەکاردێت لە فۆرمی
/// زیادکردنی بەرهەم (Admin) و لە فلتەری گەڕان.
const List<String> productLanguages = ['کوردی', 'عەرەبی', 'ئینگلیزی'];

// ============================================================
// SAMPLE PRODUCTS
// ============================================================

// تێبینی: createdAt پێویستی بە DateTime.now() هەیە، بۆیە ئەم
// بەرهەمە نموونەیانە چیتر 'const' نین (تەنها 'final' ماونەتەوە).
final DateTime _now = DateTime.now();

final List<Product> sampleProducts = [
  Product(
    id: 'mizani_2023',
    title: 'Mizani 2023',
    category: 'پەرتوک',
    description:
        'بەرهەمێکی ئەکادیمی بۆ خوێندکاران. پێش کڕین دەتوانیت Preview ـی PDF ببینیت.',
    author: 'ZNAR Academy',
    rating: 4.8,
    reviews: 126,
    oldPrice: 20000.0,
    price: 13000.0,
    icon: Icons.menu_book_rounded,
    color: secondaryPurple,
    pdfAsset: 'assets/pdf/Mizani 2023.pdf',
    createdAt: _now.subtract(const Duration(days: 1)),
  ),
  Product(
    id: 'academic_report',
    title: 'ڕاپۆرتی ئەکادیمی',
    category: 'ڕاپۆرت',
    description:
        'نموونەیەکی ڕاپۆرتی ئەکادیمی بە شێوەیەکی پاک و پرۆفیشناڵ.',
    author: 'ZNAR Academy',
    rating: 4.7,
    reviews: 82,
    oldPrice: 15000.0,
    price: 10000.0,
    icon: Icons.description_outlined,
    color: primaryBlue,
    createdAt: _now.subtract(const Duration(days: 4)),
  ),
  Product(
    id: 'scientific_research',
    title: 'توێژینەوەی زانستی',
    category: 'توێژینەوە',
    description:
        'توێژینەوەیەکی ڕێکخراو بۆ خوێندکارانی زانکۆ.',
    author: '          NAR Academy',
    rating: 4.9,
    reviews: 54,
    oldPrice: 25000.0,
    price: 18000.0,
    icon: Icons.science_outlined,
    color: Colors.cyan,
    createdAt: _now.subtract(const Duration(days: 10)),
  ),
  Product(
    id: 'academic_template',
    title: 'Academic Template',
    category: 'تێمپلەیت',
    description:
        'تێمپلەیتی جوان و مۆدێرن بۆ کارە ئەکادیمییەکان.',
    author: 'ZNAR Academy',
    rating: 4.6,
    reviews: 41,
    oldPrice: 10000.0,
    price: 7000.0,
    icon: Icons.dashboard_customize_outlined,
    color: Colors.orange,
    createdAt: _now.subtract(const Duration(days: 20)),
  ),
];

// ============================================================
// PRODUCTS (Cloud Firestore)
// ============================================================
// بەرهەمەکان ئێستا لە کۆلیکشنی 'products' ی Firestore دێن،
// نەک ڕاستەوخۆ لە sampleProducts. sampleProducts هێشتا
// دەمێنێتەوە وەک "seed data" — یەکەم جار کە ئەپەکە کاردەکات،
// ئەگەر کۆلیکشنەکە بەتاڵ بێت، ئەم بەرهەمە نموونەییانە
// خۆکارانە بۆ Firestore بار دەکرێن.

CollectionReference<Map<String, dynamic>> _productsRef() {
  return FirebaseFirestore.instance.collection('products');
}

/// لیستی زیندووی هەموو بەرهەمەکان لە Firestore
/// [activeOnly] ئەگەر true بێت، تەنها بەرهەمە چالاکەکان (isActive)
/// دەگەڕێنێتەوە — بۆ بەکارهێنان لە شوێنە دۆزینەوەییەکان (Home،
/// Search، ProductListScreen). بۆ Admin Panel و Library/Favorites
/// بەتاڵ (false) دەهێڵدرێت، تاکو بەرهەمە شاراوەکانیش دەربکەون.
Stream<List<Product>> productsStream({bool activeOnly = false}) {
  return _productsRef().snapshots().map(
        (snap) => snap.docs
            .map((d) => Product.fromMap(d.id, d.data()))
            .where((p) => !activeOnly || p.isActive)
            .toList(),
      );
}

/// ئەگەر کۆلیکشنی 'products' بەتاڵ بێت، بەرهەمە نموونەییەکان
/// (sampleProducts) بۆی بار دەکات. تەنها یەک جار ڕوودەدات.
Future<void> seedProductsIfEmpty() async {
  try {
    final snapshot = await _productsRef().limit(1).get();
    if (snapshot.docs.isNotEmpty) return; // پێشتر داتای هەیە

    for (final product in sampleProducts) {
      await _productsRef().doc(product.id).set(product.toMap());
    }
  } catch (e) {
    // ئەگەر ئینتەرنێت نەبوو یان هەڵەیەکی تر ڕوویدا، هیچ ناکەین؛
    // ئەپەکە بەردەوام دەبێت بە sampleProducts وەک fallback.
  }
}

// ============================================================
// CATEGORIES (Cloud Firestore)
// ============================================================
// هەمان شێواز وەک Products: sampleCategories وەک seed data
// بەکاردێت، پاشان هەموو شتێک لە کۆلیکشنی 'categories' ی
// Firestore دەخوێنرێتەوە.

class Category {
  final String id;
  final String title;
  final IconData icon;
  final Color color;

  const Category({
    required this.id,
    required this.title,
    required this.icon,
    required this.color,
  });

  factory Category.fromMap(String id, Map<String, dynamic> map) {
    return Category(
      id: id,
      title: map['title'] as String? ?? '',
      icon: IconData(
        // ignore: non_const_argument_for_const_parameter
        (map['iconCodePoint'] as num?)?.toInt() ??
            Icons.category_outlined.codePoint,
        fontFamily: 'MaterialIcons',
      ),
      color: Color(
        (map['colorValue'] as num?)?.toInt() ?? primaryBlue.toARGB32(),
      ),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'iconCodePoint': icon.codePoint,
      'colorValue': color.toARGB32(),
    };
  }
}

final List<Category> sampleCategories = [
  const Category(
    id: 'book',
    title: 'پەرتوک',
    icon: Icons.menu_book_rounded,
    color: secondaryPurple,
  ),
  const Category(
    id: 'report',
    title: 'ڕاپۆرت',
    icon: Icons.description_outlined,
    color: primaryBlue,
  ),
  const Category(
    id: 'research',
    title: 'توێژینەوە',
    icon: Icons.science_outlined,
    color: Colors.cyan,
  ),
  const Category(
    id: 'seminar',
    title: 'سیمینار',
    icon: Icons.present_to_all_outlined,
    color: successColor,
  ),
  const Category(
    id: 'template',
    title: 'تێمپلەیت',
    icon: Icons.dashboard_customize_outlined,
    color: Colors.orange,
  ),
  const Category(
    id: 'cv',
    title: 'CV',
    icon: Icons.badge_outlined,
    color: Colors.teal,
  ),
  const Category(
    id: 'ministry_exams',
    title: 'ئەزمونێن وزاری',
    icon: Icons.fact_check_outlined,
    color: Colors.redAccent,
  ),
  const Category(
    id: 'helper_books',
    title: 'پەرتوکێن هاریکار',
    icon: Icons.auto_stories_outlined,
    color: Colors.indigo,
  ),
];

CollectionReference<Map<String, dynamic>> _categoriesRef() {
  return FirebaseFirestore.instance.collection('categories');
}

/// ئایکۆن و ڕەنگی بەردەست بۆ دروستکردن/دەستکاریکردنی پۆل لە
/// Admin Panel — کورتەیەکن لە دیزاینی ئەپەکە بۆ ئەوەی گونجاو بن.
const Map<String, IconData> categoryIconOptions = {
  'پەرتووک': Icons.menu_book_rounded,
  'ڕاپۆرت': Icons.description_outlined,
  'توێژینەوە': Icons.science_outlined,
  'سیمینار': Icons.present_to_all_outlined,
  'تێمپلەیت': Icons.dashboard_customize_outlined,
  'CV': Icons.badge_outlined,
  'ئەزموون': Icons.fact_check_outlined,
  'هاریکار': Icons.auto_stories_outlined,
  'پرسیار': Icons.quiz_outlined,
  'قوتابخانە': Icons.school_outlined,
  'ئەرک': Icons.assignment_outlined,
  'فۆڵدەر': Icons.folder_outlined,
};

const Map<String, Color> categoryColorOptions = {
  'شین': primaryBlue,
  'مۆر': secondaryPurple,
  'سەوز': successColor,
  'سوور': errorColor,
  'زێڕی': accentGold,
  'تیل': Colors.teal,
  'ئیندیگۆ': Colors.indigo,
  'پرینجالی': Colors.orange,
  'شینی ئاسمانی': Colors.cyan,
};

/// لیستی زیندووی هەموو پۆلەکان لە Firestore
Stream<List<Category>> categoriesStream() {
  return _categoriesRef().snapshots().map(
        (snap) => snap.docs
            .map((d) => Category.fromMap(d.id, d.data()))
            .toList(),
      );
}

/// ئەگەر کۆلیکشنی 'categories' بەتاڵ بێت، پۆلە
/// نموونەییەکان (sampleCategories) بۆی بار دەکات.
Future<void> seedCategoriesIfEmpty() async {
  try {
    final snapshot = await _categoriesRef().limit(1).get();
    if (snapshot.docs.isNotEmpty) return;

    for (final category in sampleCategories) {
      await _categoriesRef().doc(category.id).set(category.toMap());
    }
  } catch (e) {
    // fallback بۆ sampleCategories دەمێنێتەوە
  }
}

// ============================================================
// AD BANNERS (Cloud Firestore) — کۆنترۆڵکراو لەلایەن Admin
// ============================================================

class AppBanner {
  final String id;
  final String title;
  final String subtitle;
  final String? imageUrl;
  final int order;
  final bool isVisible;

  const AppBanner({
    required this.id,
    required this.title,
    required this.subtitle,
    this.imageUrl,
    this.order = 0,
    this.isVisible = true,
  });

  factory AppBanner.fromMap(String id, Map<String, dynamic> map) {
    return AppBanner(
      id: id,
      title: map['title'] as String? ?? '',
      subtitle: map['subtitle'] as String? ?? '',
      imageUrl: map['imageUrl'] as String?,
      order: (map['order'] as num?)?.toInt() ?? 0,
      isVisible: map['isVisible'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'subtitle': subtitle,
      if (imageUrl != null) 'imageUrl': imageUrl,
      'order': order,
      'isVisible': isVisible,
      'createdAt': FieldValue.serverTimestamp(),
    };
  }
}

final List<AppBanner> sampleBanners = [
  const AppBanner(
    id: 'banner_new',
    title: 'بەرهەمێن نوی',
    subtitle: 'هەموو پێداویستییە ئەکادیمییەکانت لە یەک شوێن.',
    order: 0,
  ),
  const AppBanner(
    id: 'banner_discount',
    title: 'داشکاندنێن تایبەت',
    subtitle: 'هەموو پێداویستییە ئەکادیمییەکانت لە یەک شوێن.',
    order: 1,
  ),
  const AppBanner(
    id: 'banner_books',
    title: 'پەرتوک و ڕاپۆرتێن ئەکادیمی',
    subtitle: 'هەموو پێداویستییە ئەکادیمییەکانت لە یەک شوێن.',
    order: 2,
  ),
];

CollectionReference<Map<String, dynamic>> _bannersRef() {
  return FirebaseFirestore.instance.collection('banners');
}

Stream<List<AppBanner>> bannersStream() {
  return _bannersRef().orderBy('order').snapshots().map(
        (snap) => snap.docs
            .map((d) => AppBanner.fromMap(d.id, d.data()))
            .toList(),
      );
}

// ------------------------------------------------------------
// کاتی خۆکارانە سووڕانەوەی بانەرەکان (چەند چرکە هەر بانەرێک
// دەردەکەوێت پێش ئەوەی بگوازرێتەوە بۆ ئەوی دواتر). ئەدمین
// دەتوانێت ئەمە بگۆڕێت لە AdminBannersScreen.
// ------------------------------------------------------------

Future<int> getBannerIntervalSeconds() async {
  final doc = await FirebaseFirestore.instance
      .collection('settings')
      .doc('appConfig')
      .get();
  final seconds = doc.data()?['bannerIntervalSeconds'] as num?;
  return seconds?.toInt() ?? 4;
}

Future<void> setBannerIntervalSeconds(int seconds) async {
  await FirebaseFirestore.instance
      .collection('settings')
      .doc('appConfig')
      .set({'bannerIntervalSeconds': seconds}, SetOptions(merge: true));
}

Future<void> seedBannersIfEmpty() async {
  try {
    final snapshot = await _bannersRef().limit(1).get();
    if (snapshot.docs.isNotEmpty) return;

    for (final banner in sampleBanners) {
      await _bannersRef().doc(banner.id).set(banner.toMap());
    }
  } catch (e) {
    // fallback بۆ sampleBanners دەمێنێتەوە
  }
}

Future<void> deleteBanner(String id) async {
  await _bannersRef().doc(id).delete();
}

/// تەنها ڕیکلامە چالاکەکان (isVisible == true) دەگەڕێنێتەوە،
/// بۆ بەکارهێنان لە پەڕەی سەرەکیدا.
Stream<List<AppBanner>> visibleBannersStream() {
  return bannersStream().map(
    (banners) => banners.where((b) => b.isVisible).toList(),
  );
}

/// دۆخی پیشاندانی ڕیکلامێک (چالاک/ناچالاک) دەگۆڕێت، بەبێ
/// ئەوەی فیلدەکانی تر (order/createdAt) بگۆڕدرێن.
Future<void> toggleBannerVisibility(String id, bool isVisible) async {
  await _bannersRef().doc(id).update({'isVisible': isVisible});
}

// ============================================================
// COUPONS (Cloud Firestore) — کۆنترۆڵکراو لەلایەن Admin
// ============================================================
// کۆپۆنەکان لە ژێر کۆلیکشنی 'coupons' خەزن دەکرێن، ناسنامەی
// هەر بەڵگەنامەیەک خودی کۆدی کۆپۆنەکەیە (بە پیتی گەورە)، تاکو
// پشکنینی دروستی خێرا بێت (بەبێ query).

class Coupon {
  final String code;
  final int discountPercent;
  final bool active;

  const Coupon({
    required this.code,
    required this.discountPercent,
    this.active = true,
  });

  factory Coupon.fromMap(String id, Map<String, dynamic> map) {
    return Coupon(
      code: (map['code'] as String?) ?? id,
      discountPercent: (map['discountPercent'] as num?)?.toInt() ?? 0,
      active: map['active'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'code': code,
      'discountPercent': discountPercent,
      'active': active,
      'createdAt': FieldValue.serverTimestamp(),
    };
  }
}

CollectionReference<Map<String, dynamic>> _couponsRef() {
  return FirebaseFirestore.instance.collection('coupons');
}

Stream<List<Coupon>> couponsStream() {
  return _couponsRef().snapshots().map(
        (snap) => snap.docs
            .map((d) => Coupon.fromMap(d.id, d.data()))
            .toList()
          ..sort((a, b) => a.code.compareTo(b.code)),
      );
}

Future<void> addCoupon({
  required String code,
  required int discountPercent,
}) async {
  final normalized = code.trim().toUpperCase();
  await _couponsRef().doc(normalized).set(
        Coupon(code: normalized, discountPercent: discountPercent).toMap(),
      );
}

Future<void> setCouponActive(String code, bool active) async {
  await _couponsRef().doc(code.toUpperCase()).update({'active': active});
}

Future<void> deleteCoupon(String code) async {
  await _couponsRef().doc(code.toUpperCase()).delete();
}

/// پشکنینی دروستی کۆدی کۆپۆنێک. ئەگەر بوونی هەبوو و چالاک بوو،
/// ڕێژەی داشکاندنی (بە سەدا) دەگەڕێنێتەوە؛ ئەگەرنا null.
Future<int?> validateCoupon(String code) async {
  final normalized = code.trim().toUpperCase();
  if (normalized.isEmpty) return null;

  final doc = await _couponsRef().doc(normalized).get();
  if (!doc.exists) return null;

  final data = doc.data()!;
  if (data['active'] != true) return null;

  return (data['discountPercent'] as num?)?.toInt();
}

// ============================================================
// FAVORITES (Cloud Firestore)
// ============================================================
// دڵخوازەکان لە ژێر: users/{uid}/favorites/{productId} خەزن
// دەکرێن. تەنها ناسنامەی بەرهەمەکە خەزن دەکرێت؛ زانیارییەکانی
// بەرهەمەکە خۆی لە کۆلیکشنی 'products' دێت.

CollectionReference<Map<String, dynamic>>? _favoritesRef() {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return null;

  return FirebaseFirestore.instance
      .collection('users')
      .doc(user.uid)
      .collection('favorites');
}

Future<bool> isProductFavorited(String productId) async {
  final ref = _favoritesRef();
  if (ref == null) return false;

  final doc = await ref.doc(productId).get();
  return doc.exists;
}

Future<void> toggleFavorite(String productId) async {
  final ref = _favoritesRef();
  if (ref == null) return;

  final doc = await ref.doc(productId).get();

  if (doc.exists) {
    await ref.doc(productId).delete();
  } else {
    await ref.doc(productId).set({
      'addedAt': FieldValue.serverTimestamp(),
    });
  }
}

/// لیستی زیندووی ناسنامەی هەموو بەرهەمە دڵخوازەکان
Stream<Set<String>> favoriteIdsStream() {
  final ref = _favoritesRef();
  if (ref == null) return Stream.value(<String>{});

  return ref.snapshots().map(
        (snap) => snap.docs.map((d) => d.id).toSet(),
      );
}

// ============================================================
// LIBRARY (Cloud Firestore)
// ============================================================
// بەرهەمە کڕدراوەکان لە ژێر: users/{uid}/library/{productId}
// خەزن دەکرێن. ئێستا، لەبەر ئەوەی سیستەمی ڕاستەقینەی
// پارەدان (FIB Payment) هێشتا جێبەجێ نەکراوە (مەرحەلە ٣ی
// داهاتوو)، کاتێک "بەردەوامبوون بۆ پارەدان" دەکرێت، بەرهەمەکە
// ڕاستەوخۆ زیاد دەکرێت بۆ لایبراری وەک کڕینێکی سیمولەیشن.

CollectionReference<Map<String, dynamic>>? _libraryRef() {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return null;

  return FirebaseFirestore.instance
      .collection('users')
      .doc(user.uid)
      .collection('library');
}

Future<void> addToLibrary(String productId) async {
  final ref = _libraryRef();
  if (ref == null) return;

  await ref.doc(productId).set({
    'purchasedAt': FieldValue.serverTimestamp(),
  });
}

/// پشکنین دەکات ئایا ئەم بەرهەمە پێشتر کڕدراوە و لە
/// لایبراری بەکارهێنەردایە یان نا (بۆ لابردنی سنووری Preview).
Future<bool> isProductInLibrary(String productId) async {
  final ref = _libraryRef();
  if (ref == null) return false;

  final doc = await ref.doc(productId).get();
  return doc.exists;
}

/// لیستی زیندووی ناسنامەی هەموو بەرهەمە کڕدراوەکان
Stream<Set<String>> libraryIdsStream() {
  final ref = _libraryRef();
  if (ref == null) return Stream.value(<String>{});

  return ref.snapshots().map(
        (snap) => snap.docs.map((d) => d.id).toSet(),
      );
}

// ============================================================
// CART (Cloud Firestore)
// ============================================================
// سەبەتەی کڕین لە ژێر: users/{uid}/cart/{productId} خەزن
// دەکرێت. هەر بەرهەمێک تەنها یەک جار دەتوانێت لە سەبەتەدا
// هەبێت (بەرهەمە دیجیتاڵییەکانن، پێویستی بە "دانە" نییە).

CollectionReference<Map<String, dynamic>>? _cartRef() {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return null;

  return FirebaseFirestore.instance
      .collection('users')
      .doc(user.uid)
      .collection('cart');
}

Future<bool> isProductInCart(String productId) async {
  final ref = _cartRef();
  if (ref == null) return false;

  final doc = await ref.doc(productId).get();
  return doc.exists;
}

/// زیادکردن/لابردنی بەرهەمێک لە سەبەتە (وەک toggleFavorite).
Future<void> toggleCart(String productId) async {
  final ref = _cartRef();
  if (ref == null) return;

  final doc = await ref.doc(productId).get();

  if (doc.exists) {
    await ref.doc(productId).delete();
  } else {
    await ref.doc(productId).set({
      'addedAt': FieldValue.serverTimestamp(),
    });
  }
}

Future<void> removeFromCart(String productId) async {
  final ref = _cartRef();
  if (ref == null) return;
  await ref.doc(productId).delete();
}

/// لیستی زیندووی ناسنامەی هەموو بەرهەمەکانی ناو سەبەتە
Stream<Set<String>> cartIdsStream() {
  final ref = _cartRef();
  if (ref == null) return Stream.value(<String>{});

  return ref.snapshots().map(
        (snap) => snap.docs.map((d) => d.id).toSet(),
      );
}

/// ژمارەی بەرهەمەکانی ناو سەبەتە (بۆ بادجی سەر ئایکۆن)
Stream<int> cartCountStream() => cartIdsStream().map((s) => s.length);

/// وازهێنان لە سەبەتە بە تەواوی (بۆ پاش تەواوبوونی کڕین)
Future<void> clearCart() async {
  final ref = _cartRef();
  if (ref == null) return;

  final snap = await ref.get();
  final batch = FirebaseFirestore.instance.batch();
  for (final doc in snap.docs) {
    batch.delete(doc.reference);
  }
  await batch.commit();
}

// ============================================================
// FIB PAYMENT (First Iraqi Bank)
// ============================================================
// بەڵگەنامەی FIB: https://fib.iq/integrations/web-payments/
//
// ⚠️ گرنگ: پێش بەکارهێنان، دەبێت لە fib.iq وەک بازرگان تۆمار
// بیت و client_id/client_secret ـی sandbox وەربگریت. تا ئەو
// کاتە، ئەم دوو نرخە placeholder ـن و کارناکەن.

class FibConfig {
  static const String clientId = 'YOUR_FIB_CLIENT_ID';
  static const String clientSecret = 'YOUR_FIB_CLIENT_SECRET';

  // بۆ تاقیکردنەوە (sandbox). دوای وەرگرتنی credentials ی
  // production لە FIB، ئەم URL ـە بگۆڕە بەوەی FIB پێت دەڵێت.
  static const String baseUrl = 'https://fib.stage.fib.iq';

  // ئەگەر callback URL ـت هەیە (وەک Cloud Function) لێرە
  // بینووسە. بۆ دۆخی polling، دەتوانرێت null بمێنێتەوە.
  static const String? statusCallbackUrl = null;
}

class FibPaymentException implements Exception {
  final String message;
  FibPaymentException(this.message);

  @override
  String toString() => message;
}

class FibPaymentService {
  /// وەرگرتنی Access Token ـی نوێ (OAuth2 Client Credentials).
  /// تێبینی: FIB tokenـەکە تەنها ٦٠ چرکە کاردەکات، بۆیە هەر
  /// جارێک پێش داواکارییەک تۆکنێکی نوێ وەردەگرین.
  Future<String> _getAccessToken() async {
    final uri = Uri.parse(
      '${FibConfig.baseUrl}/auth/realms/fib-online-shop/protocol/openid-connect/token',
    );

    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'client_credentials',
        'client_id': FibConfig.clientId,
        'client_secret': FibConfig.clientSecret,
      },
    );

    if (response.statusCode != 200) {
      throw FibPaymentException(
        'نەتوانرا پەیوەندی بە FIB بکرێت (${response.statusCode}).',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['access_token'] as String;
  }

  /// دروستکردنی پارەدانێکی نوێ. amountIQD دەبێت بە IQD بێت.
  /// دەگەڕێتەوە: paymentId, qrCode, readableCode,
  /// personalAppLink, businessAppLink, validUntil.
  Future<Map<String, dynamic>> createPayment({
    required double amountIQD,
    required String description,
  }) async {
    final token = await _getAccessToken();
    final uri = Uri.parse('${FibConfig.baseUrl}/protected/v1/payments');

    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'monetaryValue': {
          'amount': amountIQD.toStringAsFixed(2),
          'currency': 'IQD',
        },
        if (FibConfig.statusCallbackUrl != null)
          'statusCallbackUrl': FibConfig.statusCallbackUrl,
        // description ـی FIB زۆرترین درێژی ٥٠ پیتە
        'description': description.length > 50
            ? description.substring(0, 50)
            : description,
      }),
    );

    if (response.statusCode != 202) {
      throw FibPaymentException(
        'نەتوانرا پارەدانەکە دروست بکرێت (${response.statusCode}).',
      );
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// پشکنینی دۆخی پارەدانێک. دەگەڕێتەوە: status
  /// (PAID / UNPAID / DECLINED) و زانیاری تر.
  Future<Map<String, dynamic>> checkPaymentStatus(String paymentId) async {
    final token = await _getAccessToken();
    final uri = Uri.parse(
      '${FibConfig.baseUrl}/protected/v1/payments/$paymentId/status',
    );

    final response = await http.get(
      uri,
      headers: {'Authorization': 'Bearer $token'},
    );

    if (response.statusCode != 200) {
      throw FibPaymentException(
        'نەتوانرا دۆخی پارەدان بپشکێردرێت (${response.statusCode}).',
      );
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> cancelPayment(String paymentId) async {
    final token = await _getAccessToken();
    final uri = Uri.parse(
      '${FibConfig.baseUrl}/protected/v1/payments/$paymentId/cancel',
    );

    await http.post(
      uri,
      headers: {'Authorization': 'Bearer $token'},
    );
  }
}

final FibPaymentService fibPaymentService = FibPaymentService();

// ============================================================
// ORDERS (پارەدانی دەستی + پشتڕاستکردنەوەی ئەدمین)
// ============================================================
// چونکە هەژمارەکەت لە FIB شەخسییە (نەک بازرگانی)، ناتوانین
// API ـی ڕاستەقینەی FIB بەکاربهێنین. لەبری ئەوە: بەکارهێنەر
// پارە بە دەستی دەنێرێت بۆ ژمارەی FIB ـی تۆ، وەسڵێک بار
// دەکات، و داواکارییەکە دەچێتە کۆلیکشنی 'orders' بە دۆخی
// 'pending'. دواتر لە Admin Panel (یان ئێستا، ڕاستەوخۆ لە
// Firebase Console) پشتڕاستی دەکرێتەوە.
//
// ژمارە/کۆدی FIB ـی خۆت لێرە بنووسە بۆ پیشاندان بە
// بەکارهێنەران:
// نیشانەی '\u2066' (LRI) و '\u2069' (PDI) دەوری ژمارەکە دەگرن بۆ
// ئەوەی هەمیشە بە ڕیزبەندی دروست (چەپ بۆ ڕاست) پیشان بدرێت،
// تەنانەت کاتێک لەناو دەقی کوردی (ڕاستەوچەپ) دەنووسرێت.
const String fibPaymentPhoneNumber = '+964 750 730 5828';
const String fibPaymentAccountName = 'ZNAR IDREES SADEQ';

CollectionReference<Map<String, dynamic>> _ordersRef() =>
    FirebaseFirestore.instance.collection('orders');

/// دروستکردنی داواکارییەکی نوێی کڕین، وەسڵەکە بار دەکات بۆ
/// Firebase Storage، و بەڵگەنامەیەک لە 'orders' دروست دەکات.
Future<String> createOrder({
  required List<Product> items,
  required double totalIQD,
  String? couponCode,
  required File receiptImage,
}) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) {
    throw Exception('پێویستە بچیتە ژوورەوە.');
  }

  final orderRef = _ordersRef().doc();

  final receiptUrl = await uploadToSupabase(
    bucket: 'receipts',
    path: '${orderRef.id}.jpg',
    file: receiptImage,
  );

  await orderRef.set({
    'userId': user.uid,
    'userEmail': user.email,
    'items': items
        .map((p) => {
              'id': p.id,
              'title': p.title,
              'price': p.price,
            })
        .toList(),
    'totalIQD': totalIQD,
    'couponCode': couponCode,
    'receiptUrl': receiptUrl,
    'status': 'pending', // pending | approved | rejected
    'libraryGranted': false,
    'createdAt': FieldValue.serverTimestamp(),
  });

  // ئاگادارکردنەوەی ئەدمین (تەنها ئەدمین، نەک هەموو بەکارهێنەران)
  // بەوەی داواکارییەکی نوێی کڕین هاتووە، تاکو وەسڵەکە پشکنین
  // بکات و فایلی دۆکیومێنتی بەرهەمەکە بۆ کڕیار بەردەست بکات.
  // Cloud Function ـێک (وەک send_notifications_function.js)
  // گوێدەگرێت بۆ بەڵگەنامەی نوێ لێرە و پوش‌notification ـی
  // ڕاستەقینە دەنێرێت بۆ topic ی 'admin_alerts' (بڕوانە
  // setupPushNotifications).
  try {
    final itemTitles = items.map((p) => p.title).join('، ');
    await FirebaseFirestore.instance.collection('admin_alerts').add({
      'type': 'new_order',
      'topic': 'admin_alerts',
      'title': 'داواکارییەکی نوێی کڕین 🛒',
      'body': '${user.email ?? 'کڕیارێک'} داوای کڕینی $itemTitles کرد.',
      'orderId': orderRef.id,
      'userId': user.uid,
      'userEmail': user.email,
      'totalIQD': totalIQD,
      'createdAt': FieldValue.serverTimestamp(),
    });
  } catch (_) {
    // ئاگادارکردنەوەکە شکستی هێنا — کارەکەی سەرەکی (دروستکردنی
    // order) پێشتر تەواو بووە، بۆیە هەڵەکە پشتگوێ دەخەین تاکو
    // کڕیار کاریگەری لەسەر نەبینێت.
  }

  return orderRef.id;
}

/// لیستی زیندووی هەموو داواکارییەکانی کڕینی ئەم بەکارهێنەرە،
/// نوێترین سەرەتا.
Stream<List<Map<String, dynamic>>> myOrdersStream() {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return Stream.value(<Map<String, dynamic>>[]);

  return _ordersRef()
      .where('userId', isEqualTo: user.uid)
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map(
        (snap) => snap.docs
            .map((d) => {...d.data(), 'id': d.id})
            .toList(),
      );
}

/// ژمارەی داواکارییە چاوەڕوانەکان (status == 'pending') — بەکاردێت
/// بۆ badge ـی ئاگادارکردنەوەی ئەدمین لە Profile و Admin Panel،
/// وەک شێوازێکی سادە بەبێ پێویست بە Cloud Function/push notification.
Stream<int> pendingOrdersCountStream() {
  return _ordersRef()
      .where('status', isEqualTo: 'pending')
      .snapshots()
      .map((snap) => snap.docs.length);
}


/// فەنکشنە بەرهەمەکانی ئەو داواکارییە دەخاتە Library ی
/// بەکارهێنەرەکە و 'libraryGranted' ڕاستی دادەنێت (تاکو دووجار
/// زیاد نەکرێت).
Future<void> grantLibraryForOrderIfNeeded(
  Map<String, dynamic> order,
) async {
  if (order['status'] != 'approved') return;
  if (order['libraryGranted'] == true) return;

  final items = (order['items'] as List<dynamic>? ?? []);
  for (final item in items) {
    final id = (item as Map)['id'] as String?;
    if (id != null) {
      await addToLibrary(id);
    }
  }

  await _ordersRef().doc(order['id'] as String).update({
    'libraryGranted': true,
  });
}

// ============================================================
// ADMIN
// ============================================================
// ئەدمین بوون بە بوونی بەڵگەنامەیەک لە کۆلیکشنی 'admins' دەبڕدرێت
// (بەڵگەنامەیەک بە ناسنامەی uid ـی بەکارهێنەرەکە). ئەم
// کۆلیکشنە تەنها لە Firebase Console دەتوانرێت دەستکاری بکرێت
// (لە Firestore Security Rules ـدا write بۆ کڵایەنت ڕاگیراوە)،
// بۆیە هیچ بەکارهێنەرێک ناتوانێت خۆی بکاتە ئەدمین.
//
// بۆ دیاریکردنی یەکەم ئەدمین: بڕۆ Firebase Console → Firestore
// → کۆلیکشنی 'admins' دروست بکە → بەڵگەنامەیەک زیاد بکە بە
// ID یەکسان بە UID ـی هەژمارەکەت (لە پەڕەی Profile کۆپی بکە)
// → هەر فیلدێک تێیدا بنووسە، بۆ نموونە role: 'owner'.

Stream<bool> isAdminStream() {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return Stream.value(false);

  return FirebaseFirestore.instance
      .collection('admins')
      .doc(user.uid)
      .snapshots()
      .map((doc) => doc.exists);
}

Future<bool> isCurrentUserAdmin() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return false;

  final doc = await FirebaseFirestore.instance
      .collection('admins')
      .doc(user.uid)
      .get();

  return doc.exists;
}

// ============================================================
// ADMIN ROLES (ڕۆڵی ئەدمین — هەر ئەدمینێک تەنها بەشی خۆی ببینێت)
// ============================================================
// بەڵگەنامەی admins/{uid} دەتوانێت فیلدی 'roles' (لیستی
// ڕیزبەند) هەبێت، بۆ نموونە: ['products', 'orders']. ئەگەر
// 'owner' تێدابێت یان بەتاڵ بێت (یان بەڵگەنامەکە هیچ فیلدێکی
// role نەبێت — وەک یەکەم ئەدمینی کۆن)، ئەوا دەستڕاگەیشتنی
// تەواوی هەیە بۆ هەموو بەشەکان.

const List<String> kAdminRoleKeys = [
  'orders',
  'products',
  'categories',
  'users',
  'stats',
  'banners',
  'coupons',
  'notifications',
  'requests',
];

const Map<String, String> kAdminRoleLabels = {
  'orders': 'داواکارییەکان',
  'products': 'بەرهەمەکان',
  'categories': 'پۆلەکان',
  'users': 'بەکارهێنەران',
  'stats': 'ئامار',
  'banners': 'ڕیکلامەکان',
  'coupons': 'کۆپۆنەکان',
  'notifications': 'ڕاگەیاندنەکان',
  'requests': 'داواکاریا فایلان',
};

/// ڕۆڵەکانی ئەدمینی ئێستا دەگەڕێنێتەوە. لیستێکی بەتاڵ مانای
/// "دەستڕاگەیشتنی تەواو" (owner) دەگەیەنێت.
Future<List<String>> currentAdminRoles() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return [];

  final doc = await FirebaseFirestore.instance
      .collection('admins')
      .doc(user.uid)
      .get();

  if (!doc.exists) return [];

  final data = doc.data();
  if (data == null) return [];

  if (data['roles'] is List) {
    return (data['roles'] as List).map((e) => e.toString()).toList();
  }
  // پشتگیری فۆرماتی کۆن (فیلدێکی تاکە بەناوی 'role')
  if (data['role'] is String) {
    return [data['role'] as String];
  }

  return [];
}

bool adminCanAccess(List<String> roles, String key) {
  if (roles.isEmpty) return true; // owner / کۆن
  if (roles.contains('owner')) return true;
  return roles.contains(key);
}

bool adminIsOwner(List<String> roles) {
  return roles.isEmpty || roles.contains('owner');
}

Stream<List<Map<String, dynamic>>> allAdminsStream() {
  return FirebaseFirestore.instance.collection('admins').snapshots().map(
        (snap) => snap.docs.map((d) => {...d.data(), 'uid': d.id}).toList(),
      );
}

Future<void> setAdminRoles(String uid, List<String> roles) async {
  await FirebaseFirestore.instance.collection('admins').doc(uid).set({
    'roles': roles,
    'updatedAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));
}

Future<void> removeAdmin(String uid) async {
  await FirebaseFirestore.instance.collection('admins').doc(uid).delete();
}

// ============================================================
// USER MANAGEMENT (بلۆککردن + مێژووی کڕین)
// ============================================================

Future<void> toggleUserBlocked(String uid, bool blocked) async {
  await FirebaseFirestore.instance.collection('users').doc(uid).set(
    {'blocked': blocked},
    SetOptions(merge: true),
  );
}

/// مێژووی هەموو داواکارییەکانی کڕینی بەکارهێنەرێکی دیاریکراو
/// (بۆ بەکارهێنانی ئەدمین، نەک خودی بەکارهێنەرەکە).
Stream<List<Map<String, dynamic>>> userOrdersStreamFor(String uid) {
  return FirebaseFirestore.instance
      .collection('orders')
      .where('userId', isEqualTo: uid)
      .snapshots()
      .map((snap) {
    final items = snap.docs.map((d) => {...d.data(), 'id': d.id}).toList();
    items.sort((a, b) {
      final ta = a['createdAt'];
      final tb = b['createdAt'];
      if (ta is! Timestamp || tb is! Timestamp) return 0;
      return tb.compareTo(ta);
    });
    return items;
  });
}

/// Stream ـی دۆخی بلۆککردنی بەکارهێنەری ئێستا، بە شێوەی
/// ڕاستەوخۆ (real-time). پشکنینی 'blocked' لە کاتی Login
/// تەنها یەک جار پشکنین دەکات؛ ئەم stream ـە پێویستە بۆ ئەو
/// حاڵەتەی بەکارهێنەرێک پێشتر چووەتە ژوورەوە (session پارێزراوە)
/// یان ئەدمین لە کاتی بەکارهێنانی ئەپەکەدا بلۆکی دەکات.
Stream<bool> currentUserBlockedStream() {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return Stream.value(false);
  return FirebaseFirestore.instance
      .collection('users')
      .doc(user.uid)
      .snapshots()
      .map((doc) => doc.data()?['blocked'] as bool? ?? false);
}

// ============================================================
// BLOCKED ACCOUNT
// ============================================================

class BlockedAccountScreen extends StatelessWidget {
  const BlockedAccountScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: Colors.redAccent.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.block_rounded,
                  size: 52,
                  color: Colors.redAccent,
                ),
              ),
              const SizedBox(height: 22),
              Text(
                'هەژمارەکەت ڕاگیراوە',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: darkText,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'دەستپێگەیشتنت بۆ ئەم ئەپە ڕاگیراوە لەلایەن '
                'بەڕێوەبەرایەتییەوە. ئەگەر پێت وایە ئەمە هەڵەیە، '
                'تکایە پەیوەندیمان پێوە بکە.',
                textAlign: TextAlign.center,
                style: TextStyle(color: secondaryText, height: 1.5),
              ),
              const SizedBox(height: 30),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    await FirebaseAuth.instance.signOut();
                    if (!context.mounted) return;
                    Navigator.pushAndRemoveUntil(
                      context,
                      MaterialPageRoute(builder: (_) => const LoginScreen()),
                      (route) => false,
                    );
                  },
                  icon: const Icon(Icons.logout_rounded),
                  label: const Text(
                    'چوونەدەرەوە',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// HOME
// ============================================================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int currentIndex = 0;
  int bannerIndex = 0;

  final PageController bannerController = PageController(
    viewportFraction: 0.90,
  );

  List<AppBanner> banners = sampleBanners;
  StreamSubscription<List<AppBanner>>? _bannersSub;

  @override
  void initState() {
    super.initState();

    // تۆمارکردنی ئەم ئامێرە بۆ وەرگرتنی ڕاگەیاندنەکان (FCM)،
    // کاتێک بەکارهێنەر چووەتە ناو ئەپەکە (لێرە، Home، دوای
    // Login یان دوای Splash ئەگەر session ـی چالاکی هەبوو).
    setupPushNotifications();

    _bannersSub = visibleBannersStream().listen((data) {
      if (data.isNotEmpty && mounted) {
        setState(() => banners = data);
      }
    });

    // کاتی سووڕانەوەی بانەر لە ڕێکخستنەکانی ئەدمینەوە وەردەگیرێت
    // (بنەڕەتی ٤ چرکەیە ئەگەر ئەدمین نەیگۆڕیبێت).
    getBannerIntervalSeconds().then((seconds) {
      if (!mounted) return;
      _startBannerTimer(seconds);
    });
  }

  void _startBannerTimer(int seconds) {
    Timer.periodic(Duration(seconds: seconds), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      // یەک بانەر یان هیچ — پێویست بە سووڕانەوە نییە.
      if (banners.length < 2) return;

      bannerIndex++;

      if (bannerIndex >= banners.length) {
        bannerIndex = 0;
      }

      if (bannerController.positions.length == 1) {
        bannerController.animateToPage(
          bannerIndex,
          duration: const Duration(milliseconds: 750),
          curve: Curves.easeInOutCubic,
        );
      }

      setState(() {});
    });
  }

  @override
  void dispose() {
    _bannersSub?.cancel();
    bannerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: currentUserBlockedStream(),
      builder: (context, blockedSnapshot) {
        if (blockedSnapshot.data == true) {
          return const BlockedAccountScreen();
        }

        final pages = [
          _buildHome(),
          const LibraryScreen(),
          const RequestCustomFileScreen(embedded: true),
          const FavoritesScreen(),
          const ProfileScreen(),
        ];

        return Scaffold(
          extendBody: true,
          body: pages[currentIndex],
          bottomNavigationBar: _FloatingBottomNav(
            currentIndex: currentIndex,
            onTap: (index) => setState(() => currentIndex = index),
          ),
        );
      },
    );
  }

  /// بەشێکی هاریزۆنتاڵی بەرهەمەکان بۆ سەرەکی (نوێ/باو/داشکاندن).
  /// هەموو سێ بەشەکە هەمان stream و هەمان ڕوانگە بەکاردێنن،
  /// تەنها لۆجیکی فلتەر/ڕیزکردن جیاوازە (لە ProductListScreen).
  Widget _homeProductSection({
    required String title,
    required ProductListType type,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _sectionTitle(title),
            TextButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ProductListScreen(type: type),
                  ),
                );
              },
              child: const Text('هەمی'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 355,
          child: StreamBuilder<List<Product>>(
            stream: productsStream(activeOnly: true),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final all = snapshot.data ?? sampleProducts;

              final products = ProductListScreen(type: type)
                  ._apply(all)
                  .take(10)
                  .toList();

              if (products.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: snapshot.connectionState ==
                            ConnectionState.waiting
                        ? const CircularProgressIndicator()
                        : Text(
                            type == ProductListType.offers
                                ? 'هیچ داشکاندنێک نییە.'
                                : 'هیچ بەرهەمێک نییە.',
                            style: TextStyle(
                              color: secondaryText,
                            ),
                          ),
                  ),
                );
              }

              return ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: products.length,
                itemBuilder: (context, index) {
                  return ProductCard(product: products[index]);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _onRefresh() async {
    // داتای بەرهەم/کاتیگۆری/ڕیکلامەکان خۆیان بە شێوەی زیندوو
    // (Stream) نوێ دەبنەوە لە Firestore، بۆیە پێویست بە
    // داواکارییەکی تایبەت نییە — تەنها دەلاچێینەوە بۆ ئەوەی
    // ئەنیمەیشنی Refresh بەکارهێنەر ببینێت و دڵنیابێت نوێترین
    // داتا لای خۆیەتی.
    await refreshWithFeedback(context, [
      _productsRef(),
      _categoriesRef(),
      _bannersRef(),
    ]);
  }

  // ============================================================
  // BANNERS (ڕیکلام) — کارتی گەورەی خڕ، بانەری داهاتوو کەمێک دیارە،
  // ئەنیمەیشنی نەرم (Scale + Fade + Parallax)، و نیشانەی خاڵەکان کە
  // لەگەڵ کێشانی پەنجە بە نەرمی دەگۆڕدرێن.
  // ============================================================

  /// ئایا controller ـەکە تەنها بە یەک PageView ـەوە بەستراوە؟
  /// (لە کاتی Hot Reload یان گۆڕانی پێکهاتەی widget ـەکان، بۆ ساتێک
  /// دوو PageView بە یەک controller ـەوە دەبن و `position` هەڵە دەدات.)
  bool get _bannerReady =>
      bannerController.positions.length == 1 &&
      bannerController.position.haveDimensions;

  double _bannerPage() {
    if (_bannerReady) {
      return bannerController.page ?? bannerIndex.toDouble();
    }
    return bannerIndex.toDouble();
  }

  Widget _buildBannerSection() {
    final screenWidth = MediaQuery.sizeOf(context).width;
    // پانی هەر بانەرێک = (پانی شاشە − پادینگ) × viewportFraction.
    // بەرزی ١٠٠٪ گونجاوە لەگەڵ ڕێژەی 8:5 ـی crop ـەی
    // AdminBannersScreen (بەرزی = پانی × ٥/٨)، تاکو وێنەکە
    // بەبێ بڕینێکی خراپ بەتەواوی دەردەکەوێت.
    final pageWidth = (screenWidth - 36) * 0.90;
    final height = (pageWidth * 0.625).clamp(190.0, 280.0).toDouble();
    final dir = Directionality.of(context) == TextDirection.rtl ? -1.0 : 1.0;
    final inactiveDot =
        isDarkMode ? Colors.grey.shade700 : Colors.grey.shade300;

    return Column(
      children: [
        SizedBox(
          height: height,
          child: PageView.builder(
            controller: bannerController,
            physics: const BouncingScrollPhysics(),
            itemCount: banners.length,
            onPageChanged: (index) {
              setState(() => bannerIndex = index);
            },
            itemBuilder: (context, index) {
              final banner = banners[index];

              return AnimatedBuilder(
                animation: bannerController,
                builder: (context, _) {
                  final delta = (_bannerPage() - index).clamp(-1.0, 1.0).toDouble();
                  final dist = delta.abs();

                  return Transform.scale(
                    scale: 1 - dist * 0.06,
                    child: Opacity(
                      opacity: 1 - dist * 0.30,
                      child: _bannerCard(banner, delta, dir),
                    ),
                  );
                },
              );
            },
          ),
        ),

        if (banners.length > 1) ...[
          const SizedBox(height: 14),
          AnimatedBuilder(
            animation: bannerController,
            builder: (context, _) {
              final page = _bannerPage();

              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(banners.length, (i) {
                  final t = (1 - (page - i).abs()).clamp(0.0, 1.0).toDouble();

                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3.5),
                    width: 9 + 22 * t,
                    height: 9,
                    decoration: BoxDecoration(
                      color: Color.lerp(inactiveDot, primaryBlue, t),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  );
                }),
              );
            },
          ),
        ],
      ],
    );
  }

  Widget _bannerCard(AppBanner banner, double delta, double dir) {
    final hasImage = banner.imageUrl != null;
    final radius = BorderRadius.circular(30);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: hasImage ? cardSurfaceColor : null,
        gradient: hasImage ? null : brandGradient,
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDarkMode ? 0.35 : 0.12),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // وێنەکە: Parallax سووک (لەگەڵ کێشان بە نەرمی دەجوڵێت)
            // + Fade-in کاتێک بار دەبێت. بەبێ zoom‌ی زیادە، تاکو
            // وێنەی ئەدمین وەک خۆی و بەبێ بڕینێکی زیادە دەردەکەوێت.
            if (hasImage)
              Transform.translate(
                offset: Offset(delta * 14 * dir, 0),
                child: Image.network(
                  banner.imageUrl!,
                  fit: BoxFit.cover,
                  frameBuilder: (context, child, frame, wasSync) {
                    if (wasSync) return child;
                    return AnimatedOpacity(
                      opacity: frame == null ? 0 : 1,
                      duration: const Duration(milliseconds: 450),
                      curve: Curves.easeOut,
                      child: child,
                    );
                  },
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),

            // بازنەی ڕازاوە (تەنها کاتێک وێنە نییە)
            if (!hasImage)
              Positioned(
                top: -30,
                right: -30,
                child: Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
              ),
            if (!hasImage)
              Positioned(
                bottom: -50,
                left: -20,
                child: Container(
                  width: 160,
                  height: 160,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.06),
                  ),
                ),
              ),

            // تۆنی تاریک تەنها کاتێک ئەدمین ناونیشانی نووسیوە؛
            // ئەگەر نا، وێنەکە بە تەواوی پاک دەمێنێتەوە.
            if (hasImage && banner.title.isNotEmpty)
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.10),
                      Colors.black.withValues(alpha: 0.60),
                    ],
                  ),
                ),
              ),

            if (banner.title.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.3),
                          width: 1,
                        ),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.auto_awesome_rounded,
                            color: Colors.white,
                            size: 13,
                          ),
                          SizedBox(width: 5),
                          Text(
                            'ZNAR ACADEMY',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          banner.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            height: 1.2,
                          ),
                        ),
                        if (banner.subtitle.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            banner.subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),

            // لێوارێکی نەرمی تەنک (وەک نموونەکە)
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(
                    color: (isDarkMode ? Colors.white : Colors.black)
                        .withValues(alpha: isDarkMode ? 0.18 : 0.06),
                    width: 1.2,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHome() {
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _onRefresh,
        color: primaryBlue,
        child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 132),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const AppLogo(size: 48),

                const SizedBox(width: 12),

                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'بخێرهاتی',
                        style: TextStyle(
                          color: secondaryText,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        'ZNAR Academy',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: darkText,
                        ),
                      ),
                    ],
                  ),
                ),

                Container(
                  decoration: BoxDecoration(
                    color: cardSurfaceColor,
                    shape: BoxShape.circle,
                    boxShadow: softShadow(opacity: 0.05, blur: 12),
                  ),
                  child: StreamBuilder<int>(
                    stream: cartCountStream(),
                    builder: (context, snapshot) {
                      final count = snapshot.data ?? 0;

                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          IconButton(
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const CartScreen(),
                                ),
                              );
                            },
                            icon: Icon(
                              Icons.shopping_cart_outlined,
                              size: 24,
                              color: darkText,
                            ),
                          ),
                          if (count > 0)
                            Positioned(
                              top: 4,
                              right: 4,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 1,
                                ),
                                decoration: const BoxDecoration(
                                  color: Colors.redAccent,
                                  shape: BoxShape.circle,
                                ),
                                constraints: const BoxConstraints(
                                  minWidth: 16,
                                  minHeight: 16,
                                ),
                                child: Text(
                                  '$count',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),

                const SizedBox(width: 6),

                Container(
                  decoration: BoxDecoration(
                    color: cardSurfaceColor,
                    shape: BoxShape.circle,
                    boxShadow: softShadow(opacity: 0.05, blur: 12),
                  ),
                  child: StreamBuilder<List<Map<String, dynamic>>>(
                    stream: broadcastsStream(),
                    builder: (context, snapshot) {
                      final items = snapshot.data ?? [];

                      return FutureBuilder<DateTime?>(
                        future: lastSeenNotificationsAt(),
                        builder: (context, lastSeenSnap) {
                          final lastSeen = lastSeenSnap.data;
                          final hasUnread = items.any((item) {
                            final createdAt = item['createdAt'];
                            if (createdAt is! Timestamp) return false;
                            if (lastSeen == null) return true;
                            return createdAt.toDate().isAfter(lastSeen);
                          });

                          return Stack(
                            clipBehavior: Clip.none,
                            children: [
                              IconButton(
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          const NotificationsScreen(),
                                    ),
                                  ).then((_) => setState(() {}));
                                },
                                icon: Icon(
                                  Icons.notifications_none_rounded,
                                  size: 24,
                                  color: darkText,
                                ),
                              ),
                              if (hasUnread)
                                Positioned(
                                  top: 8,
                                  right: 8,
                                  child: Container(
                                    width: 9,
                                    height: 9,
                                    decoration: const BoxDecoration(
                                      color: Colors.redAccent,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),

            const SizedBox(height: 25),

            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const SearchScreen(),
                  ),
                );
              },
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(17),
                  boxShadow: softShadow(opacity: 0.04, blur: 14),
                ),
                child: AbsorbPointer(
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'گەڕان بەدوای بەرهەمێک...',
                      prefixIcon: const Icon(Icons.search),
                      filled: true,
                      fillColor: cardSurfaceColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(17),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 22),

            // BANNER
            _buildBannerSection(),

            const SizedBox(height: 27),

            _sectionTitle('بەشەکان'),

            const SizedBox(height: 14),

            SizedBox(
              height: 105,
              child: StreamBuilder<List<Category>>(
                stream: categoriesStream(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting &&
                      !snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final categories = snapshot.data ?? sampleCategories;

                  return ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: categories.length,
                    itemBuilder: (context, index) {
                      final category = categories[index];

                      return CategoryCard(
                        title: category.title,
                        icon: category.icon,
                        color: category.color,
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => CategoryProductsScreen(
                                category: category,
                              ),
                            ),
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ),

            const SizedBox(height: 28),

            _homeProductSection(
              title: 'بەرهەمێن نوی',
              type: ProductListType.newest,
            ),

            const SizedBox(height: 25),

            _homeProductSection(
              title: 'باوترین بەرهەمەکان',
              type: ProductListType.popular,
            ),

            const SizedBox(height: 25),

            _homeProductSection(
              title: 'داشکاندنەکان',
              type: ProductListType.offers,
            ),
          ],
        ),
        ),
      ),
    );
  }
}

// ============================================================
// FLOATING BOTTOM NAV — تابی خوارەوەی خڕ (Pill)، ئایکۆن + لەیبڵ
// بۆ هەر تابێک، و تابی چالاک لەناو چوارگۆشەیەکی خڕ دەردەکەوێت.
//  • دۆخی تاریک: پشتەوەی تاریکی تەواو.
//  • دۆخی ڕووناک: شەفاف (Glass) لەگەڵ Blur ـی نەرم.
// ============================================================

class _FloatingBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _FloatingBottomNav({
    required this.currentIndex,
    required this.onTap,
  });

  // دۆخی تاریک
  static const Color _darkBase = Color(0xFF1C1C1E);
  static const Color _darkSelectedFill = Color(0xFF3A3A3C);
  static const Color _darkRim = Color(0xB3B8B8BD);
  static const Color _darkInactive = Color(0xFF8E8E93);

  // دۆخی ڕووناک
  static const Color _lightInactive = Color(0xFF6B7280);
  static const Color _lightLabel = Color(0xFF0F172A);

  // ڕیزبەندی: سەرەکی · پەرتوکخانە · داواکاری (ناوەڕاست) · حەزکری · پرۆفایل
  static const _labels = [
    'سەرەکی',
    'پەرتوکخانە',
    'داواکاری',
    'حەزکری',
    'پرۆفایل',
  ];

  // ئایکۆنی سەرەکی (index 0) پیتی Z ـە، لۆگۆی ئەپەکە.
  static const _icons = [
    Icons.home_outlined,
    Icons.library_books_outlined,
    Icons.post_add_outlined,
    Icons.favorite_border_rounded,
    Icons.person_outline_rounded,
  ];

  static const _selectedIcons = [
    Icons.home_rounded,
    Icons.library_books_rounded,
    Icons.post_add_rounded,
    Icons.favorite_rounded,
    Icons.person_rounded,
  ];

  Widget _icon(int i, bool selected, Color inactive) {
    final color = selected ? primaryBlue : inactive;

    if (i == 0) {
      return SizedBox(
        height: 28,
        width: 28,
        child: Center(
          child: Opacity(
            opacity: selected ? 1.0 : 0.55,
            child: Image.asset(
              'assets/images/logo2.png',
              width: 26,
              height: 26,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stack) => Text(
                'Z',
                style: TextStyle(
                  color: color,
                  fontSize: 27,
                  fontWeight: FontWeight.w900,
                  height: 1,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Icon(
      selected ? _selectedIcons[i] : _icons[i],
      color: color,
      size: 28,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final base = isDark ? _darkBase : Colors.white.withValues(alpha: 0.50);
    final rim = isDark ? _darkRim : Colors.black.withValues(alpha: 0.08);
    final selectedFill =
        isDark ? _darkSelectedFill : Colors.white.withValues(alpha: 0.70);
    final selectedRim = isDark ? _darkRim : Colors.black.withValues(alpha: 0.10);
    final inactive = isDark ? _darkInactive : _lightInactive;
    final selectedLabel = isDark ? Colors.white : _lightLabel;

    final pill = Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: base,
        borderRadius: BorderRadius.circular(36),
        border: Border.all(color: rim, width: 1.5),
      ),
      child: Row(
        children: List.generate(_labels.length, (i) {
          final selected = i == currentIndex;

          return Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onTap(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                padding: const EdgeInsets.symmetric(
                  vertical: 10,
                  horizontal: 2,
                ),
                decoration: BoxDecoration(
                  color: selected ? selectedFill : Colors.transparent,
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(
                    color: selected ? selectedRim : Colors.transparent,
                    width: 1.4,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _icon(i, selected, inactive),
                    const SizedBox(height: 4),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _labels[i],
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight:
                              selected ? FontWeight.w800 : FontWeight.w500,
                          color: selected ? selectedLabel : inactive,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );

    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: isDark
          // تاریک: پشتەوەی تەواو + سێبەر
          ? DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(36),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 26,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: pill,
            )
          // ڕووناک: شەفاف + Blur (ناوەڕۆکی خوارەوە بە نەرمی دیارە)
          : ClipRRect(
              borderRadius: BorderRadius.circular(36),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: pill,
              ),
            ),
    );
  }
}

// ============================================================
// CATEGORY CARD
// ============================================================

class CategoryCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  const CategoryCard({
    super.key,
    required this.title,
    required this.icon,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
      width: 84,
      margin: const EdgeInsets.only(right: 10),
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: cardSurfaceColor,
        borderRadius: BorderRadius.circular(18),
        boxShadow: softShadow(opacity: 0.045, blur: 14),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  color.withValues(alpha: 0.18),
                  color.withValues(alpha: 0.08),
                ],
              ),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              icon,
              color: color,
              size: 24,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: darkText,
            ),
          ),
        ],
      ),
        ),
      ),
    );
  }
}

// ============================================================
// CATEGORY PRODUCTS
// ============================================================

class CategoryProductsScreen extends StatelessWidget {
  final Category category;

  const CategoryProductsScreen({
    super.key,
    required this.category,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: Text(category.title),
      ),
      body: AppRefresh(
        queries: [
          FirebaseFirestore.instance
              .collection('products')
              .where('category', isEqualTo: category.title),
        ],
        child: StreamBuilder<List<Product>>(
        // پرسیارێکی Firestore کە تەنها بەرهەمەکانی ئەم پۆلە
        // دەهێنێت (category == category.title)
        stream: FirebaseFirestore.instance
            .collection('products')
            .where('category', isEqualTo: category.title)
            .snapshots()
            .map(
              (snap) => snap.docs
                  .map((d) => Product.fromMap(d.id, d.data()))
                  .toList(),
            ),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final products = snapshot.data ?? [];

          if (products.isEmpty) {
            return EmptyState(
              icon: category.icon,
              message: 'هیچ بەرهەمێک لەم پۆلەدا نییە.',
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(18),
            itemCount: products.length,
            itemBuilder: (context, index) {
              return _FavoriteTile(product: products[index]);
            },
          );
        },
      )),
    );
  }
}

// ============================================================
// PRODUCT LIST SCREEN (New / Popular / Offers)
// ============================================================

/// جۆرەکانی لیستی گشتی بەرهەمەکان کە دەتوانرێت لە پەڕەی
/// سەرەکییەوە بکرێنە "هەمی".
enum ProductListType { newest, popular, offers }

class ProductListScreen extends StatelessWidget {
  final ProductListType type;

  const ProductListScreen({super.key, required this.type});

  String get _title {
    switch (type) {
      case ProductListType.newest:
        return 'بەرهەمێن نوی';
      case ProductListType.popular:
        return 'باوترین بەرهەمەکان';
      case ProductListType.offers:
        return 'داشکاندنەکان';
    }
  }

  /// لۆجیکی فلتەر/ڕیزکردن بەپێی جۆرەکە. هەموو شتێک لێرە
  /// کۆدەبێتەوە تاکو HomeScreen و ئەم پەڕەیە هەمان
  /// ڕەفتار بەکاربهێنن.
  List<Product> _apply(List<Product> products) {
    // بەرهەمی 'showOnHome = false' لە هەموو بەشەکانی سەرەکی
    // (نوێ/باو/داشکاندن) دەشاردرێتەوە — هێشتا لەناو کەتەگۆری
    // خۆی و گەڕاندا دەردەکەوێت.
    final visible = products.where((p) => p.showOnHome).toList();

    switch (type) {
      case ProductListType.newest:
        final sorted = [...visible];
        sorted.sort((a, b) {
          final da = a.createdAt;
          final db = b.createdAt;
          if (da == null && db == null) return 0;
          if (da == null) return 1;
          if (db == null) return -1;
          return db.compareTo(da); // نوێترین سەرەتا
        });
        return sorted;

      case ProductListType.popular:
        final sorted = [...visible];
        sorted.sort((a, b) {
          // بەرهەمی باوتر: ڕەیتینگی بەرزتر، پاشان زۆرترین ڕەوی
          final byRating = b.rating.compareTo(a.rating);
          if (byRating != 0) return byRating;
          return b.reviews.compareTo(a.reviews);
        });
        return sorted;

      case ProductListType.offers:
        return visible.where((p) => p.isOffer).toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(title: Text(_title)),
      body: AppRefresh(
        queries: [_productsRef()],
        child: StreamBuilder<List<Product>>(
        stream: productsStream(activeOnly: true),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final products = _apply(snapshot.data ?? sampleProducts);

          if (products.isEmpty) {
            return EmptyState(
              icon: type == ProductListType.offers
                  ? Icons.local_offer_outlined
                  : Icons.menu_book_rounded,
              message: type == ProductListType.offers
                  ? 'هیچ داشکاندنێک لە ئێستادا نییە.'
                  : 'هیچ بەرهەمێک نییە.',
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(18),
            itemCount: products.length,
            itemBuilder: (context, index) {
              return _FavoriteTile(product: products[index]);
            },
          );
        },
      )),
    );
  }
}

// ============================================================
// PRODUCT CARD
// ============================================================

// ============================================================
// PRODUCT THUMBNAIL (وێنەی بەرهەم یان ئایکۆن وەک fallback)
// ============================================================
// ئەگەر بەرهەمەکە coverImageUrl ـی هەبوو (لە ڕێگەی Admin Panel
// بارکراوە)، وێنەکە پیشان دەدرێت. ئەگەر نا، هەمان ئایکۆن و
// ڕەنگی پێشووی بەکاردێت (بۆ ئەوەی بەرهەمە کۆنەکانیش خۆش دیار بن).

class ProductThumbnail extends StatefulWidget {
  final Product product;
  final double? width;
  final double? height;
  final double iconSize;
  final double borderRadius;

  const ProductThumbnail({
    super.key,
    required this.product,
    this.width,
    this.height,
    this.iconSize = 28,
    this.borderRadius = 14,
  });

  @override
  State<ProductThumbnail> createState() => _ProductThumbnailState();
}

class _ProductThumbnailState extends State<ProductThumbnail> {
  // ئایا وێنەکە "ئاسۆیی" یە (پانی لە درێژی زیاترە، وەک
  // تێمپلەیتی پاوەرپۆینت) یان "ستوونی" یە (وەک بەرگی پەرتووک).
  // بەبێ ئەم زانیارییە (هێشتا وێنەکە دانەبەزیوە)، وا دادەنرێت
  // ستوونییە، چونکە زۆربەی بەرهەمەکان پەرتووک/ڕاپۆرتن.
  bool? _isLandscape;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void didUpdateWidget(covariant ProductThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.product.coverImageUrl != widget.product.coverImageUrl) {
      _isLandscape = null;
      _resolveAspectRatio();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveAspectRatio();
  }

  void _resolveAspectRatio() {
    final url = widget.product.coverImageUrl;
    if (url == null || url.isEmpty) return;

    final newStream =
        NetworkImage(url).resolve(createLocalImageConfiguration(context));
    if (newStream.key == _stream?.key) return;

    if (_listener != null) {
      _stream?.removeListener(_listener!);
    }

    _listener = ImageStreamListener((info, _) {
      if (!mounted) return;
      final landscape = info.image.width > info.image.height;
      if (_isLandscape != landscape) {
        setState(() => _isLandscape = landscape);
      }
    });

    _stream = newStream;
    _stream!.addListener(_listener!);
  }

  @override
  void dispose() {
    if (_listener != null) {
      _stream?.removeListener(_listener!);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final product = widget.product;
    final hasCover =
        product.coverImageUrl != null && product.coverImageUrl!.isNotEmpty;

    // بۆ وێنەی ئاسۆیی (پان)، BoxFit.contain بەکاردێت لەسەر
    // پاشبنەمایەکی نەرم، بۆ ئەوەی هیچ بەشێکی وێنەکە نەبڕدرێت.
    // بۆ وێنەی ستوونی (وەک بەرگی پەرتووک)، BoxFit.cover دەکەوێتە
    // کار، چونکە چوارچێوەکە خۆی ستوونییە و بە سروشتی گونجاوە.
    final fit = _isLandscape == true ? BoxFit.contain : BoxFit.cover;

    return Stack(
      children: [
        Container(
          width: widget.width,
          height: widget.height,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                product.color.withValues(alpha: 0.18),
                product.color.withValues(alpha: 0.06),
              ],
            ),
            borderRadius: BorderRadius.circular(widget.borderRadius),
          ),
          child: hasCover
              ? Image.network(
                  product.coverImageUrl!,
                  fit: fit,
                  loadingBuilder: (context, child, progress) {
                    if (progress == null) return child;
                    return Center(
                      child: SizedBox(
                        width: widget.iconSize * 0.6,
                        height: widget.iconSize * 0.6,
                        child: const CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  },
                  errorBuilder: (context, error, stack) => Center(
                    child: Icon(
                      product.icon,
                      color: product.color,
                      size: widget.iconSize,
                    ),
                  ),
                )
              : Center(
                  child: Icon(
                    product.icon,
                    color: product.color,
                    size: widget.iconSize,
                  ),
                ),
        ),

        // هێمای تاج — تەنها لەسەر بەرهەمە بەهادارەکان دەردەکەوێت،
        // تاکو لە بەرهەمە بەخۆڕاییەکان جودا بکرێنەوە.
        if (!product.isFree)
          Positioned(
            top: 6,
            left: 6,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.amber.shade600,
                shape: BoxShape.circle,
                boxShadow: softShadow(opacity: 0.18, blur: 4),
              ),
              child: Icon(
                Icons.workspace_premium_rounded,
                size: widget.iconSize * 0.36,
                color: Colors.white,
              ),
            ),
          ),
      ],
    );
  }
}

class ProductCard extends StatelessWidget {
  final Product product;

  const ProductCard({
    super.key,
    required this.product,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 172,
      margin: const EdgeInsets.only(right: 13),
      decoration: BoxDecoration(
        color: cardSurfaceColor,
        borderRadius: BorderRadius.circular(kRadiusMd),
        boxShadow: softShadow(opacity: 0.05, blur: 16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ProductDetailsScreen(
                  product: product,
                ),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.all(11),
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                Container(
                  height: 215,
                  width: double.infinity,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: ProductThumbnail(
                    product: product,
                    width: double.infinity,
                    height: 215,
                    iconSize: 55,
                    borderRadius: 16,
                  ),
                ),
                Positioned(
                  top: 6,
                  left: 6,
                  child: StreamBuilder<Set<String>>(
                    stream: favoriteIdsStream(),
                    builder: (context, snapshot) {
                      final isFav =
                          snapshot.data?.contains(product.id) ?? false;

                      return GestureDetector(
                        onTap: () => toggleFavorite(product.id),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.9),
                            shape: BoxShape.circle,
                            boxShadow: softShadow(opacity: 0.08, blur: 6),
                          ),
                          child: Icon(
                            isFav ? Icons.favorite : Icons.favorite_border,
                            size: 16,
                            color: isFav ? Colors.red : secondaryText,
                          ),
                        ),
                      );
                    },
                  ),
                ),
                if (product.isOffer)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: successColor,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '-${product.discountPercent}%',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
              ],
            ),

            const SizedBox(height: 10),

            Text(
              product.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),

            const SizedBox(height: 5),

            Row(
              children: [
                Expanded(
                  child: Text(
                    product.category,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: product.color,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: primaryBlue.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    product.language,
                    style: const TextStyle(
                      fontSize: 10,
                      color: primaryBlue,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),

            const Spacer(),

            Row(
              children: [
                const Icon(
                  Icons.star,
                  color: Colors.amber,
                  size: 17,
                ),
                const SizedBox(width: 4),
                Text(
                  product.rating.toString(),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 6),

            Row(
              children: [
                if (product.isFree)
                  const SizedBox.shrink()
                else ...[
                  if (product.isOffer) ...[
                    Text(
                      formatIQD(product.oldPrice),
                      style: TextStyle(
                        color: secondaryText,
                        fontSize: 12,
                        decoration: TextDecoration.lineThrough,
                      ),
                    ),
                    const SizedBox(width: 5),
                  ],
                  Flexible(
                    child: Text(
                      formatIQD(product.price),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: primaryBlue,
                        fontWeight: FontWeight.bold,
                        fontSize: 17,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// PRODUCT DETAILS
// ============================================================

class ProductDetailsScreen extends StatefulWidget {
  final Product product;

  const ProductDetailsScreen({
    super.key,
    required this.product,
  });

  @override
  State<ProductDetailsScreen> createState() =>
      _ProductDetailsScreenState();
}

class _ProductDetailsScreenState
    extends State<ProductDetailsScreen> {
  bool favorite = false;
  bool inCart = false;
  bool isTogglingCart = false;
  bool isOwned = false;
  bool isCheckingOwnership = true;
  bool isDownloadingDocument = false;
  int selectedRating = 0;
  bool isSubmittingRating = false;
  bool hasRated = false;

  @override
  void initState() {
    super.initState();
    _loadFavoriteState();
    _loadCartState();
    _loadOwnershipState();
    _loadRatingState();
  }

  Future<void> _loadRatingState() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final doc = await FirebaseFirestore.instance
        .collection('products')
        .doc(widget.product.id)
        .collection('ratings')
        .doc(user.uid)
        .get();

    if (!mounted) return;
    if (doc.exists) {
      setState(() {
        hasRated = true;
        selectedRating = (doc.data()?['stars'] as num?)?.toInt() ?? 0;
      });
    }
  }

  Future<void> _submitRating(int stars) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('پێویستە بچیتە ژوورەوە بۆ هەڵسەنگاندن.'),
        ),
      );
      return;
    }

    setState(() => isSubmittingRating = true);

    try {
      final productRef = FirebaseFirestore.instance
          .collection('products')
          .doc(widget.product.id);
      final ratingRef = productRef.collection('ratings').doc(user.uid);

      await FirebaseFirestore.instance.runTransaction((tx) async {
        final ratingSnap = await tx.get(ratingRef);
        final productSnap = await tx.get(productRef);

        final currentRating =
            (productSnap.data()?['rating'] as num?)?.toDouble() ?? 0;
        final currentReviews =
            (productSnap.data()?['reviews'] as num?)?.toInt() ?? 0;

        if (ratingSnap.exists) {
          // نوێکردنەوەی هەڵسەنگاندنێکی پێشووی هەمان بەکارهێنەر
          final oldStars =
              (ratingSnap.data()?['stars'] as num?)?.toInt() ?? 0;
          final totalSum =
              (currentRating * currentReviews) - oldStars + stars;
          final newRating = currentReviews > 0
              ? totalSum / currentReviews
              : stars.toDouble();
          tx.update(productRef, {'rating': newRating});
        } else {
          final newReviews = currentReviews + 1;
          final newRating =
              ((currentRating * currentReviews) + stars) / newReviews;
          tx.update(productRef, {
            'rating': newRating,
            'reviews': newReviews,
          });
        }

        tx.set(ratingRef, {
          'stars': stars,
          'ratedAt': FieldValue.serverTimestamp(),
        });
      });

      if (!mounted) return;
      setState(() {
        hasRated = true;
        selectedRating = stars;
        isSubmittingRating = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('سوپاس بۆ هەڵسەنگاندنەکەت! ✅'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => isSubmittingRating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('هەڵە: $e')),
      );
    }
  }

  Future<void> _loadOwnershipState() async {
    // بەرهەمە بەخۆڕاییەکان پێویستیان بە کڕین نییە — ڕاستەوخۆ
    // وەک "کراوە" دادەنرێن، بەبێ پشکنینی Library.
    if (widget.product.isFree) {
      setState(() {
        isOwned = true;
        isCheckingOwnership = false;
      });
      return;
    }

    final owned = await isProductInLibrary(widget.product.id);
    if (!mounted) return;
    setState(() {
      isOwned = owned;
      isCheckingOwnership = false;
    });
  }

  /// داگرتنی فایلی دۆکیومێنتی ڕاستەقینە (Word/PowerPoint/Excel/ZIP)
  /// — جیاوازە لە _downloadPdf، چونکە ئەم فایلە بۆ دەستکاریکردنە
  /// نەک تەنها بینین.
  Future<void> _downloadDocument() async {
    final url = widget.product.documentUrl;
    if (url == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('فایلی دۆکیومێنتی ئەم بەرهەمە بەردەست نییە.'),
        ),
      );
      return;
    }

    setState(() => isDownloadingDocument = true);
    try {
      final uri = Uri.parse(url);
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('نەتوانرا فایلەکە بکرێتەوە.'),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('هەڵە: $e')),
      );
    } finally {
      if (mounted) setState(() => isDownloadingDocument = false);
    }
  }

  Future<void> _loadCartState() async {
    final inCartNow = await isProductInCart(widget.product.id);
    if (!mounted) return;
    setState(() => inCart = inCartNow);
  }

  Future<void> _toggleCart() async {
    setState(() => isTogglingCart = true);

    try {
      await toggleCart(widget.product.id);
      if (!mounted) return;
      setState(() {
        inCart = !inCart;
        isTogglingCart = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            inCart
                ? 'زیادکرا بۆ سەبەتە ✅'
                : 'لابرا لە سەبەتە',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => isTogglingCart = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('نەتوانرا سەبەتە نوێ بکرێتەوە.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _loadFavoriteState() async {
    final isFav = await isProductFavorited(widget.product.id);
    if (!mounted) return;
    setState(() => favorite = isFav);
  }

  Future<void> _toggleFavorite() async {
    // نوێکردنەوەی سەرووی UI ڕاستەوخۆ (optimistic update)
    setState(() => favorite = !favorite);

    try {
      await toggleFavorite(widget.product.id);
    } catch (e) {
      // ئەگەر هەڵەیەک ڕوویدا، بگەڕێوە بۆ دۆخی پێشوو
      if (!mounted) return;
      setState(() => favorite = !favorite);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('نەتوانرا دڵخواز نوێ بکرێتەوە.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final product = widget.product;

    return Scaffold(
      appBar: AppBar(
        title: const Text('وردەکاریی بەرهەم'),
        actions: [
          IconButton(
            onPressed: _toggleFavorite,
            icon: Icon(
              favorite
                  ? Icons.favorite
                  : Icons.favorite_border,
              color: favorite ? Colors.red : null,
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 270,
              width: double.infinity,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(25),
              ),
              child: ProductThumbnail(
                product: product,
                width: double.infinity,
                height: 270,
                iconSize: 100,
                borderRadius: 25,
              ),
            ),

            const SizedBox(height: 22),

            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: product.color.withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    product.category,
                    style: TextStyle(
                      color: product.color,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: primaryBlue.withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.language_rounded,
                        size: 15,
                        color: primaryBlue,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        product.language,
                        style: const TextStyle(
                          color: primaryBlue,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            Text(
              product.title,
              style: TextStyle(
                fontSize: 27,
                fontWeight: FontWeight.bold,
                color: darkText,
              ),
            ),

            const SizedBox(height: 10),

            Row(
              children: [
                const Icon(
                  Icons.star,
                  color: Colors.amber,
                  size: 20,
                ),
                const SizedBox(width: 5),
                Text(
                  '${product.rating}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  '(${product.reviews} هەڵسەنگاندن)',
                  style: TextStyle(
                    color: secondaryText,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 18),

            Row(
              children: [
                if (product.isFree)
                  const SizedBox.shrink()
                else ...[
                  Text(
                    formatIQD(product.price),
                    style: const TextStyle(
                      color: primaryBlue,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    formatIQD(product.oldPrice),
                    style: TextStyle(
                      color: secondaryText,
                      fontSize: 16,
                      decoration: TextDecoration.lineThrough,
                    ),
                  ),
                ],
              ],
            ),

            const SizedBox(height: 25),

            const Text(
              'دەربارەی بەرهەم',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 9),

            Text(
              product.description,
              style: TextStyle(
                color: secondaryText,
                fontSize: 15,
                height: 1.6,
              ),
            ),

            const SizedBox(height: 22),

            const Text(
              'نووسەر',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 7),

            Row(
              children: [
                const CircleAvatar(
                  backgroundColor: Color(0xFFEFF6FF),
                  child: Icon(
                    Icons.person_outline,
                    color: primaryBlue,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  product.author,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 22),

            const Text(
              'هەڵسەنگاندنی بەرهەم',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 8),

            Row(
              children: [
                for (int i = 1; i <= 5; i++)
                  IconButton(
                    onPressed: isSubmittingRating
                        ? null
                        : () => _submitRating(i),
                    icon: Icon(
                      i <= selectedRating
                          ? Icons.star
                          : Icons.star_border,
                      color: Colors.amber,
                      size: 28,
                    ),
                  ),
                if (isSubmittingRating)
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),

            if (hasRated)
              Padding(
                padding: EdgeInsets.only(top: 2, bottom: 6),
                child: Text(
                  'هەڵسەنگاندنی خۆتی — دەتوانیت بیگۆڕیت',
                  style: TextStyle(
                    color: secondaryText,
                    fontSize: 12.5,
                  ),
                ),
              ),

            const SizedBox(height: 28),

            // PREVIEW BUTTON
            SizedBox(
              width: double.infinity,
              height: 54,
              child: OutlinedButton.icon(
                onPressed: (product.pdfAsset == null && product.pdfUrl == null)
                    ? () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'PDF ـی ئەم بەرهەمە هێشتا زیاد نەکراوە.',
                            ),
                          ),
                        );
                      }
                    : () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ProductPreviewScreen(
                              product: product,
                            ),
                          ),
                        );
                      },
                icon: const Icon(
                  Icons.visibility_outlined,
                ),
                label: Text(
                  isOwned ? 'کردنەوەی PDF' : 'بینینی Preview',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: primaryBlue,
                  side: const BorderSide(
                    color: primaryBlue,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),

            if (product.previewVideoUrl != null) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => VideoPreviewScreen(
                          videoUrl: product.previewVideoUrl!,
                          title: product.title,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text(
                    'بینینی ڤیدیۆی پرێڤیو 🎬',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.deepPurple,
                    side: const BorderSide(color: Colors.deepPurple),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ],

            const SizedBox(height: 12),

            if (isCheckingOwnership)
              const SizedBox(
                height: 54,
                child: Center(
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else if (isOwned) ...[
              // تێبینی: دوگمەی "داگرتنی PDF" ـی ڕاستەوخۆ لێرەدا
              // بە قەستی لابردراوە — PDF تەنها لەناو شاشەی
              // ProductPreviewScreen (دوگمەی "کردنەوەی PDF" ی
              // سەرەوە) بۆ بینین و خەزنکردنی ئۆفلاینی پارێزراو
              // (encrypted) بەردەستە، تاکو سکرین شۆت/شەیرکردن/
              // دەرچوونی فایلی خاو لە دەرەوەی ئەپەکە ڕێگری لێ بکرێت.

              if (product.documentUrl != null) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: OutlinedButton.icon(
                    onPressed:
                        isDownloadingDocument ? null : _downloadDocument,
                    icon: isDownloadingDocument
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.folder_zip_outlined),
                    label: Text(
                      'داگرتنی فایلی ${product.documentFileName != null ? product.documentFileName!.split('.').last.toUpperCase() : 'دۆکیومێنت'}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: successColor,
                      side: const BorderSide(color: successColor),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
              ],
            ] else ...[
              // ADD TO CART BUTTON
              SizedBox(
                width: double.infinity,
                height: 54,
                child: OutlinedButton.icon(
                  onPressed: isTogglingCart ? null : _toggleCart,
                  icon: isTogglingCart
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          inCart
                              ? Icons.check_circle_outline
                              : Icons.add_shopping_cart_outlined,
                        ),
                  label: Text(
                    inCart ? 'لە سەبەتەدایە' : 'زیادکردن بۆ سەبەتە',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: inCart ? successColor : primaryBlue,
                    side: BorderSide(
                      color: inCart ? successColor : primaryBlue,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // BUY BUTTON
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: () {
                    showModalBottomSheet(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (_) => PurchaseSheet(
                        product: product,
                      ),
                    );
                  },
                  icon: const Icon(
                    Icons.shopping_cart_outlined,
                  ),
                  label: const Text(
                    'کڕین ئێستا',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryBlue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ],

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// REAL PDF PREVIEW
// ============================================================

// ============================================================
// VIDEO PREVIEW (بۆ ئەنیمەیشنی تێمپلەیتەکان)
// ============================================================

class VideoPreviewScreen extends StatefulWidget {
  final String videoUrl;
  final String title;

  const VideoPreviewScreen({
    super.key,
    required this.videoUrl,
    required this.title,
  });

  @override
  State<VideoPreviewScreen> createState() => _VideoPreviewScreenState();
}

class _VideoPreviewScreenState extends State<VideoPreviewScreen> {
  late final VideoPlayerController _controller;
  bool hasError = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(
      Uri.parse(widget.videoUrl),
    )
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() {});
        _controller.play();
      }).catchError((_) {
        if (!mounted) return;
        setState(() => hasError = true);
      });
    _controller.setLooping(true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: Center(
        child: hasError
            ? const Text(
                'نەتوانرا ڤیدیۆکە بار بکرێت.',
                style: TextStyle(color: Colors.white),
              )
            : _controller.value.isInitialized
                ? AspectRatio(
                    aspectRatio: _controller.value.aspectRatio,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        VideoPlayer(_controller),
                        GestureDetector(
                          onTap: () {
                            setState(() {
                              _controller.value.isPlaying
                                  ? _controller.pause()
                                  : _controller.play();
                            });
                          },
                          child: AnimatedOpacity(
                            opacity: _controller.value.isPlaying ? 0 : 1,
                            duration: const Duration(milliseconds: 200),
                            child: const Icon(
                              Icons.play_circle_fill,
                              color: Colors.white70,
                              size: 70,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : const CircularProgressIndicator(color: Colors.white),
      ),
    );
  }
}

class ProductPreviewScreen extends StatefulWidget {
  final Product product;

  const ProductPreviewScreen({
    super.key,
    required this.product,
  });

  @override
  State<ProductPreviewScreen> createState() =>
      _ProductPreviewScreenState();
}

class _ProductPreviewScreenState
    extends State<ProductPreviewScreen> {
  final PdfViewerController pdfController =
      PdfViewerController();

  static const int previewPages = 3;

  bool locked = false;
  bool redirecting = false;
  bool isOwned = false;
  bool isCheckingOwnership = true;

  Uint8List? offlineBytes;
  bool isSavingOffline = false;
  bool hasOfflineCopy = false;

  @override
  void initState() {
    super.initState();
    // ڕێگری لە سکرین شۆت و ڤیدیۆی سکرین لەناو ئەم پەڕەیە
    // (کاتێک بەرهەمەکە کراوەیت، ناوەڕۆکی پاراستراوە).
    ScreenProtector.preventScreenshotOn();
    _checkOwnership();
  }

  @override
  void dispose() {
    ScreenProtector.preventScreenshotOff();
    super.dispose();
  }

  Future<void> _checkOwnership() async {
    // بەرهەمە بەخۆڕاییەکان هەمیشە وەک "کراوە" دادەنرێن، بۆیە
    // سنووری ٣ پەڕەی Preview بۆیان جێبەجێ ناکرێت.
    if (widget.product.isFree) {
      setState(() {
        isOwned = true;
        isCheckingOwnership = false;
      });
      await _checkOfflineCopy();
      return;
    }

    final owned = await isProductInLibrary(widget.product.id);
    if (!mounted) return;
    setState(() {
      isOwned = owned;
      isCheckingOwnership = false;
    });
    if (owned) await _checkOfflineCopy();
  }

  Future<void> _checkOfflineCopy() async {
    final has = await hasOfflineProtectedCopy(widget.product.id);
    if (!has) {
      if (mounted) setState(() => hasOfflineCopy = false);
      return;
    }

    final bytes = await loadProtectedPdfOffline(widget.product.id);
    if (!mounted) return;
    setState(() {
      hasOfflineCopy = true;
      offlineBytes = bytes;
    });
  }

  Future<void> _saveOffline() async {
    final url = widget.product.pdfUrl;
    if (url == null) return;

    setState(() => isSavingOffline = true);
    try {
      await saveProtectedPdfOffline(
        productId: widget.product.id,
        pdfUrl: url,
      );
      await _checkOfflineCopy();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('بۆ بەکارهێنانی ئۆفلاین خەزن کرا ✅'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('نەتوانرا خەزن بکرێت: $e')),
      );
    } finally {
      if (mounted) setState(() => isSavingOffline = false);
    }
  }

  void handlePageChanged(PdfPageChangedDetails details) {
    // ئەگەر بەرهەمەکە پێشتر کڕدرابێت، هیچ سنوورێک نامێنێت.
    if (isOwned) return;

    if (details.newPageNumber > previewPages &&
        !redirecting &&
        !locked) {
      redirecting = true;

      pdfController.jumpToPage(previewPages);

      setState(() {
        locked = true;
      });

      Future.delayed(
        const Duration(milliseconds: 500),
        () {
          redirecting = false;
        },
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Preview'),
        actions: [
          if (isOwned && !isCheckingOwnership)
            IconButton(
              onPressed: isSavingOffline || hasOfflineCopy
                  ? null
                  : _saveOffline,
              icon: isSavingOffline
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      hasOfflineCopy
                          ? Icons.offline_pin_rounded
                          : Icons.download_for_offline_outlined,
                      color: hasOfflineCopy ? successColor : null,
                    ),
              tooltip: hasOfflineCopy
                  ? 'بۆ ئۆفلاین خەزنکراوە'
                  : 'خەزنکردن بۆ ئۆفلاین',
            ),
          if (!isCheckingOwnership)
            Container(
              margin: const EdgeInsets.only(
                right: 10,
                top: 10,
                bottom: 10,
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 5,
              ),
              decoration: BoxDecoration(
                color: (isOwned ? successColor : primaryBlue)
                    .withValues(alpha: .10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: Text(
                  isOwned ? 'کراوەیت ✅' : '3 پەڕە',
                  style: TextStyle(
                    color: isOwned ? successColor : primaryBlue,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Stack(
        children: [
          offlineBytes != null
              ? SfPdfViewer.memory(
                  offlineBytes!,
                  controller: pdfController,
                  onPageChanged: handlePageChanged,
                )
              : widget.product.pdfUrl != null
                  ? SfPdfViewer.network(
                      widget.product.pdfUrl!,
                      controller: pdfController,
                      onPageChanged: handlePageChanged,
                    )
                  : SfPdfViewer.asset(
                      widget.product.pdfAsset!,
                      controller: pdfController,
                      onPageChanged: handlePageChanged,
                    ),

          if (locked)
            Positioned.fill(
              child: Container(
                color: Colors.white.withValues(alpha: .97),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 90,
                          height: 90,
                          decoration: BoxDecoration(
                            color: primaryBlue.withValues(alpha: .10),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.lock_rounded,
                            color: primaryBlue,
                            size: 45,
                          ),
                        ),

                        const SizedBox(height: 25),

                        Text(
                          'Preview کۆتایی هات 🔒',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 25,
                            fontWeight: FontWeight.bold,
                            color: darkText,
                          ),
                        ),

                        const SizedBox(height: 12),

                        Text(
                          'تەنها ٣ پەڕەی یەکەم بۆ Preview بەردەستە.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: secondaryText,
                            fontSize: 15,
                            height: 1.5,
                          ),
                        ),

                        const SizedBox(height: 8),

                        Text(
                          'بۆ دەستگەهشتن بە تەواوی بەرهەمەکە، تکایە بیکڕە.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: secondaryText,
                            fontSize: 14,
                          ),
                        ),

                        const SizedBox(height: 28),

                        SizedBox(
                          width: double.infinity,
                          height: 55,
                          child: ElevatedButton.icon(
                            onPressed: () {
                              showModalBottomSheet(
                                context: context,
                                isScrollControlled: true,
                                backgroundColor:
                                    Colors.transparent,
                                builder: (_) => PurchaseSheet(
                                  product: widget.product,
                                ),
                              );
                            },
                            icon: const Icon(
                              Icons.shopping_cart_outlined,
                            ),
                            label: const Text(
                              'کڕینی بەرهەم',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: primaryBlue,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius:
                                    BorderRadius.circular(16),
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(height: 12),

                        TextButton(
                          onPressed: () {
                            setState(() {
                              locked = false;
                            });

                            pdfController.jumpToPage(
                              previewPages,
                            );
                          },
                          child: const Text(
                            'گەڕانەوە بۆ Preview',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ============================================================
// FIB PAYMENT SCREEN
// ============================================================

enum _FibStage { creating, waitingPayment, success, failed }

class FibPaymentScreen extends StatefulWidget {
  final List<Product> items;
  final double amountIQD;
  final String description;

  const FibPaymentScreen({
    super.key,
    required this.items,
    required this.amountIQD,
    required this.description,
  });

  @override
  State<FibPaymentScreen> createState() => _FibPaymentScreenState();
}

class _FibPaymentScreenState extends State<FibPaymentScreen> {
  _FibStage stage = _FibStage.creating;
  String? paymentId;
  Uint8List? qrBytes;
  String? readableCode;
  String? personalAppLink;
  String errorMessage = '';
  Timer? pollTimer;

  @override
  void initState() {
    super.initState();
    _startPayment();
  }

  @override
  void dispose() {
    pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _startPayment() async {
    setState(() {
      stage = _FibStage.creating;
      errorMessage = '';
    });

    try {
      final payment = await fibPaymentService.createPayment(
        amountIQD: widget.amountIQD,
        description: widget.description,
      );

      final qrDataUrl = payment['qrCode'] as String?;
      Uint8List? bytes;
      if (qrDataUrl != null && qrDataUrl.contains(',')) {
        bytes = base64Decode(qrDataUrl.split(',').last);
      }

      if (!mounted) return;

      setState(() {
        paymentId = payment['paymentId'] as String?;
        readableCode = payment['readableCode'] as String?;
        personalAppLink = payment['personalAppLink'] as String?;
        qrBytes = bytes;
        stage = _FibStage.waitingPayment;
      });

      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        stage = _FibStage.failed;
        errorMessage = e.toString();
      });
    }
  }

  /// هەر ٤ چرکە دۆخی پارەدانەکە دەپشکنین (Polling)، تاکو
  /// FIB Webhook یان backend زیاترمان نەوێت.
  void _startPolling() {
    pollTimer?.cancel();
    pollTimer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => _checkStatus(),
    );
  }

  Future<void> _checkStatus() async {
    if (paymentId == null) return;

    try {
      final result = await fibPaymentService.checkPaymentStatus(paymentId!);
      final status = result['status'] as String?;

      if (status == 'PAID') {
        pollTimer?.cancel();

        for (final product in widget.items) {
          await addToLibrary(product.id);
          await removeFromCart(product.id);
        }

        if (!mounted) return;
        setState(() => stage = _FibStage.success);
      } else if (status == 'DECLINED') {
        pollTimer?.cancel();
        if (!mounted) return;
        setState(() {
          stage = _FibStage.failed;
          errorMessage = 'پارەدانەکە ڕەتکرایەوە یان کاتی بەسەرچوو.';
        });
      }
      // ئەگەر UNPAID بوو، بەردەوام دەبین لە چاوەڕوانیکردن.
    } catch (_) {
      // کێشەی کورتخایەنی ئینتەرنێت؛ لە هەوڵی داهاتوودا هەوڵ دەدەینەوە.
    }
  }

  Future<void> _openFibApp() async {
    if (personalAppLink == null) return;
    final uri = Uri.parse(personalAppLink!);

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ئەپی FIB لەسەر ئەم مۆبایلە دانەمەزراوە.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: stage != _FibStage.waitingPayment,
      child: Scaffold(
        backgroundColor: backgroundColor,
        appBar: AppBar(title: const Text('پارەدان بە FIB')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: _buildBody(),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (stage) {
      case _FibStage.creating:
        return const Center(child: CircularProgressIndicator());

      case _FibStage.waitingPayment:
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                'کۆی گشتی: ${formatIQD(widget.amountIQD)}',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 20),
              if (qrBytes != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: softShadow(opacity: 0.06, blur: 16),
                  ),
                  child: Image.memory(
                    qrBytes!,
                    width: 220,
                    height: 220,
                  ),
                ),
              const SizedBox(height: 14),
              if (readableCode != null)
                Text(
                  'کۆد: $readableCode',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              const SizedBox(height: 20),
              Text(
                'بارکۆدەکە بە ئەپی FIB بخوێنەوە، یان دوگمەی خوارەوە دابگرە بۆ کردنەوەی ئەپی FIB',
                textAlign: TextAlign.center,
                style: TextStyle(color: secondaryText),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton.icon(
                  onPressed: personalAppLink == null ? null : _openFibApp,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('کردنەوەی ئەپی FIB'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryBlue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 28),
              const CircularProgressIndicator(),
              const SizedBox(height: 10),
              Text(
                'چاوەڕوانی پارەدانیت...',
                style: TextStyle(color: secondaryText),
              ),
            ],
          ),
        );

      case _FibStage.success:
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.check_circle,
                color: successColor,
                size: 90,
              ),
              const SizedBox(height: 16),
              const Text(
                'پارەدان سەرکەوتوو بوو! 🎉',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'بەرهەمەکان زیادکران بۆ Library ـت.',
                style: TextStyle(color: secondaryText),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: () =>
                      Navigator.popUntil(context, (r) => r.isFirst),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryBlue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text('باشە'),
                ),
              ),
            ],
          ),
        );

      case _FibStage.failed:
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                color: Colors.redAccent,
                size: 80,
              ),
              const SizedBox(height: 16),
              Text(
                errorMessage.isEmpty
                    ? 'هەڵەیەک ڕوویدا.'
                    : errorMessage,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: _startPayment,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryBlue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text('هەوڵدانەوە'),
                ),
              ),
            ],
          ),
        );
    }
  }
}

// ============================================================
// MANUAL PAYMENT (پارەدانی دەستی + وەسڵ)
// ============================================================
// چونکە هەژماری FIB شەخسییە، بەکارهێنەر خۆی پارە دەنێرێت و
// وەسڵی پارەدان بار دەکات. دواتر ئەدمین پشتڕاستی دەکاتەوە.

class ManualPaymentScreen extends StatefulWidget {
  final List<Product> items;
  final double amountIQD;
  final String? couponCode;

  const ManualPaymentScreen({
    super.key,
    required this.items,
    required this.amountIQD,
    this.couponCode,
  });

  @override
  State<ManualPaymentScreen> createState() => _ManualPaymentScreenState();
}

class _ManualPaymentScreenState extends State<ManualPaymentScreen> {
  File? receiptImage;
  bool isSubmitting = false;
  bool submitted = false;
  bool isPickingImage = false;

  Future<void> _pickReceipt() async {
    // ڕێگری لە دووبارە کرتەکردن کاتێک picker پێشتر کراوەیە
    // (ئەمە هۆکاری "already_active" errorـەکەیە).
    if (isPickingImage) return;
    isPickingImage = true;

    try {
      final picker = ImagePicker();
      final XFile? picked = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1200,
      );

      if (picked == null) return;
      if (!mounted) return;
      setState(() => receiptImage = File(picked.path));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('نەتوانرا وێنەکە هەڵبژێردرێت، تکایە دووبارە هەوڵبدەرەوە.'),
        ),
      );
    } finally {
      isPickingImage = false;
    }
  }

  Future<void> _submit() async {
    if (receiptImage == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تکایە سەرەتا وەسڵی پارەدان زیاد بکە.'),
        ),
      );
      return;
    }

    setState(() => isSubmitting = true);

    try {
      await createOrder(
        items: widget.items,
        totalIQD: widget.amountIQD,
        couponCode: widget.couponCode,
        receiptImage: receiptImage!,
      );

      // ئەگەر بەرهەمەکان لە سەبەتەوە هاتبن، لابردن
      for (final product in widget.items) {
        await removeFromCart(product.id);
      }

      if (!mounted) return;
      setState(() {
        isSubmitting = false;
        submitted = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('هەڵەیەک ڕوویدا: $e')),
      );
    }
  }

  Future<void> _openFibApp() async {
    // هەوڵدان بۆ کردنەوەی ئەپی FIB ڕاستەوخۆ. لەبەر ئەوەی FIB
    // هیچ URL scheme‌ی فەرمی بڵاونەکراوەتەوە بۆ گواستنەوەی
    // پارە بە ژمارەی پێشدیاریکراو، هەوڵ دەدەین ئەپەکە بکەینەوە
    // و ئەگەر دانەمەزرابوو، بەرەو Play Store دەچین.
    const fibScheme = 'fib://';
    const fibPlayStoreUrl =
        'https://play.google.com/store/apps/details?id=iq.fib.android';

    try {
      final opened = await launchUrl(
        Uri.parse(fibScheme),
        mode: LaunchMode.externalApplication,
      );

      if (!opened && mounted) {
        await launchUrl(
          Uri.parse(fibPlayStoreUrl),
          mode: LaunchMode.externalApplication,
        );
      }
    } catch (e) {
      if (!mounted) return;
      await launchUrl(
        Uri.parse(fibPlayStoreUrl),
        mode: LaunchMode.externalApplication,
      );
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'لە ناو FIB، پارە بنێرە بۆ \u2066$fibPaymentPhoneNumber\u2069 ($fibPaymentAccountName)',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label کۆپیکرا ✅'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(title: const Text('پارەدان')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: submitted ? _buildSuccess() : _buildForm(),
        ),
      ),
    );
  }

  Widget _buildForm() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: primaryBlue.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // FIB BADGE
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D2B4E),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.account_balance_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                      SizedBox(width: 6),
                      Text(
                        'FIB',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 14),

                const Text(
                  '١. پارەکە بنێرە بۆ:',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(
                      Icons.account_balance_wallet_outlined,
                      color: primaryBlue,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        fibPaymentAccountName,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () => _copyToClipboard(
                        fibPaymentAccountName,
                        'ناوی هەژمار',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(Icons.phone_outlined, color: primaryBlue),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Directionality(
                        textDirection: TextDirection.ltr,
                        child: SelectableText(
                          fibPaymentPhoneNumber,
                          textAlign: TextAlign.left,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () => _copyToClipboard(
                        fibPaymentPhoneNumber,
                        'ژمارەی مۆبایل',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  'کۆی گشتی: ${formatIQD(widget.amountIQD)}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                    color: primaryBlue,
                  ),
                ),

                const SizedBox(height: 14),

                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: _openFibApp,
                    icon: const Icon(Icons.launch_rounded, size: 18),
                    label: const Text(
                      'کردنەوەی ئەپی FIB بۆ پارەدان',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0D2B4E),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          const Text(
            '٢. وەسڵی پارەدان (screenshot) بار بکە:',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: _pickReceipt,
            child: Container(
              height: 190,
              width: double.infinity,
              decoration: BoxDecoration(
                color: cardSurfaceColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: receiptImage == null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.upload_file_outlined,
                            size: 36,
                            color: secondaryText,
                          ),
                          SizedBox(height: 8),
                          Text(
                            'کرتە بکە بۆ زیادکردنی وەسڵ',
                            style: TextStyle(color: secondaryText),
                          ),
                        ],
                      ),
                    )
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.file(receiptImage!, fit: BoxFit.cover),
                    ),
            ),
          ),
          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton.icon(
              onPressed: isSubmitting ? null : _submit,
              icon: isSubmitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.send_rounded),
              label: const Text(
                'ناردنی داواکاری',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryBlue,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccess() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.hourglass_top_rounded,
            color: primaryBlue,
            size: 90,
          ),
          const SizedBox(height: 16),
          const Text(
            'داواکارییەکەت نێردرا ✅',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'دوای پشتڕاستکردنەوەی پارەدان لەلایەن تیمەکەمانەوە، بەرهەمەکان خۆکارانە دەچنە Library ـت. دەتوانیت دۆخی داواکارییەکەت لە "کڕینەکانم" ببینیت.',
            textAlign: TextAlign.center,
            style: TextStyle(color: secondaryText),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton(
              onPressed: () =>
                  Navigator.popUntil(context, (r) => r.isFirst),
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryBlue,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: const Text('باشە'),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// PURCHASE HISTORY
// ============================================================

// ============================================================
// REQUEST CUSTOM FILE (داواکاریا فایلان)
// ============================================================

class RequestCustomFileScreen extends StatefulWidget {
  /// true = وەک تابی خوارەوە پیشان دەدرێت (بێ دوگمەی گەڕانەوە، و
  /// بۆشاییەک لە خوارەوە بۆ تابەکان).
  final bool embedded;

  const RequestCustomFileScreen({super.key, this.embedded = false});

  @override
  State<RequestCustomFileScreen> createState() =>
      _RequestCustomFileScreenState();
}

class _RequestCustomFileScreenState extends State<RequestCustomFileScreen> {
  final titleController = TextEditingController();
  final descriptionController = TextEditingController();
  bool isSubmitting = false;

  @override
  void dispose() {
    titleController.dispose();
    descriptionController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final title = titleController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تکایە ناونیشانی داواکارییەکە بنووسە.')),
      );
      return;
    }

    setState(() => isSubmitting = true);
    try {
      await submitFileRequest(
        title: title,
        description: descriptionController.text.trim(),
      );
      if (!mounted) return;
      titleController.clear();
      descriptionController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('داواکارییەکەت نێردرا، سوپاس ✅'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('هەڵەیەک ڕوویدا: $e')),
      );
    } finally {
      if (mounted) setState(() => isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: const Text('داواکاریا فایلان'),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(18, 18, 18, widget.embedded ? 132 : 18),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: primaryBlue.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              'ئەو بابەت یان فایلەی پێویستە بنووسە (بۆ نموونە: "تێمپلەیتێکی سیمینار لەسەر بابەتی X" یان "فایلی چارەسەرکردنی پرسیارەکان") — تیمی ئێمە هەوڵدەدات بۆتان ئامادەی بکات.',
              style: TextStyle(
                color: secondaryText,
                fontSize: 13,
                height: 1.6,
              ),
            ),
          ),

          const SizedBox(height: 20),

          Text(
            'ناونیشانی داواکارییەکە *',
            style: TextStyle(fontWeight: FontWeight.w600, color: darkText),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: titleController,
            decoration: InputDecoration(
              hintText: 'بۆ نموونە: تێمپلەیتی سیمینار — بازرگانی',
              filled: true,
              fillColor: cardSurfaceColor,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),

          const SizedBox(height: 16),

          Text(
            'زانیاری زیاتر (ئارەزوومەندانە)',
            style: TextStyle(fontWeight: FontWeight.w600, color: darkText),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: descriptionController,
            maxLines: 5,
            decoration: InputDecoration(
              hintText: 'وردەکاری زیاتر بنووسە...',
              filled: true,
              fillColor: cardSurfaceColor,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),

          const SizedBox(height: 20),

          SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton.icon(
              onPressed: isSubmitting ? null : _submit,
              icon: isSubmitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.send_rounded),
              label: const Text('ناردنی داواکاری'),
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryBlue,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),

          const SizedBox(height: 30),

          Text(
            'داواکارییەکانی من',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 15,
              color: darkText,
            ),
          ),
          const SizedBox(height: 10),

          StreamBuilder<List<Map<String, dynamic>>>(
            stream: myFileRequestsStream(),
            builder: (context, snapshot) {
              final items = snapshot.data ?? [];

              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CircularProgressIndicator()),
                );
              }

              if (items.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'هێشتا هیچ داواکارییەکت نەناردووە.',
                    style: TextStyle(color: secondaryText),
                  ),
                );
              }

              return Column(
                children: items.map((item) {
                  final fulfilled = item['status'] == 'fulfilled';
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(14),
                    decoration: softCardDecoration(),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item['title'] as String? ?? '',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: darkText,
                                ),
                              ),
                              if ((item['description'] as String? ?? '')
                                  .isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  item['description'] as String,
                                  style: TextStyle(
                                    color: secondaryText,
                                    fontSize: 12.5,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: (fulfilled ? successColor : Colors.orange)
                                .withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            fulfilled ? 'ئامادەکرا' : 'چاوەڕوان',
                            style: TextStyle(
                              color:
                                  fulfilled ? successColor : Colors.orange,
                              fontWeight: FontWeight.bold,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

class PurchaseHistoryScreen extends StatelessWidget {
  const PurchaseHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(title: const Text('کڕینەکانم')),
      body: AppRefresh(
        queries: [
          FirebaseAuth.instance.currentUser == null
              ? null
              : _ordersRef()
                  .where('userId',
                      isEqualTo: FirebaseAuth.instance.currentUser!.uid)
                  .orderBy('createdAt', descending: true),
        ],
        child: StreamBuilder<List<Map<String, dynamic>>>(
        stream: myOrdersStream(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  'هەڵە: ${snapshot.error}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: errorColor),
                ),
              ),
            );
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final orders = snapshot.data ?? [];

          if (orders.isEmpty) {
            return const EmptyState(
              icon: Icons.receipt_long_outlined,
              message: 'هێشتا هیچ کڕینێکت نییە.',
            );
          }

          // ئەگەر داواکارییەک نوێی 'approved' بووبێت، خۆکارانە
          // بەرهەمەکانی دەخاتە Library. grantLibraryForOrderIfNeeded
          // خۆی 'libraryGranted' دەپشکنێت بۆیە دووجار زیاد ناکرێت.
          for (final order in orders) {
            grantLibraryForOrderIfNeeded(order);
          }

          return ListView.builder(
            padding: const EdgeInsets.all(18),
            itemCount: orders.length,
            itemBuilder: (context, index) =>
                _OrderTile(order: orders[index]),
          );
        },
      )),
    );
  }
}

class _OrderTile extends StatelessWidget {
  final Map<String, dynamic> order;

  const _OrderTile({required this.order});

  @override
  Widget build(BuildContext context) {
    final status = order['status'] as String? ?? 'pending';
    final items = (order['items'] as List<dynamic>? ?? []);
    final total = (order['totalIQD'] as num?)?.toDouble() ?? 0;

    Color statusColor;
    String statusLabel;

    switch (status) {
      case 'approved':
        statusColor = successColor;
        statusLabel = 'پشتڕاستکرایەوە';
        break;
      case 'rejected':
        statusColor = Colors.redAccent;
        statusLabel = 'ڕەتکرایەوە';
        break;
      default:
        statusColor = Colors.orange;
        statusLabel = 'چاوەڕوان';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: softCardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  items
                      .map((i) => (i as Map)['title'].toString())
                      .join('، '),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14.5,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  statusLabel,
                  style: TextStyle(
                    color: statusColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            formatIQD(total),
            style: const TextStyle(
              color: primaryBlue,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// ADMIN PANEL
// ============================================================

class AdminHomeScreen extends StatelessWidget {
  const AdminHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(title: const Text('Admin Panel')),
      // دووبارە پشکنین لێرەش دەکرێت (سەرباری Profile) تاکو
      // ئەگەر کەسێک ڕاستەوخۆ بگاتە ئەم پەڕەیە بەبێ ڕێگای
      // Profile، هێشتا بپارێزرێت.
      body: StreamBuilder<bool>(
        stream: isAdminStream(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final isAdmin = snapshot.data ?? false;

          if (!isAdmin) {
            return Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.lock_outline,
                      size: 70,
                      color: secondaryText,
                    ),
                    SizedBox(height: 14),
                    Text(
                      'ڕێگەپێنەدراویت بۆ ئەم بەشە.',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          return FutureBuilder<List<String>>(
            future: currentAdminRoles(),
            builder: (context, rolesSnapshot) {
              if (!rolesSnapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final roles = rolesSnapshot.data!;
              final owner = adminIsOwner(roles);

              final allCards = <String, Widget>{
                'orders': StreamBuilder<int>(
                  stream: pendingOrdersCountStream(),
                  builder: (context, ordersSnapshot) {
                    return _AdminMenuCard(
                      icon: Icons.receipt_long_rounded,
                      title: 'داواکارییەکان',
                      subtitle: 'پشتڕاستکردنەوەی وەسڵ',
                      color: primaryBlue,
                      badgeCount: ordersSnapshot.data ?? 0,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const AdminOrdersScreen(),
                          ),
                        );
                      },
                    );
                  },
                ),
                'products': _AdminMenuCard(
                  icon: Icons.menu_book_rounded,
                  title: 'بەرهەمەکان',
                  subtitle: 'زیادکردن/گۆڕین/سڕینەوە',
                  color: secondaryPurple,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const AdminProductsScreen(),
                      ),
                    );
                  },
                ),
                'users': _AdminMenuCard(
                  icon: Icons.people_alt_rounded,
                  title: 'بەکارهێنەران',
                  subtitle: 'لیستی هەموو بەکارهێنەران',
                  color: Colors.teal,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const AdminUsersScreen(),
                      ),
                    );
                  },
                ),
                'categories': _AdminMenuCard(
                  icon: Icons.category_rounded,
                  title: 'پۆلەکان',
                  subtitle: 'زیادکردن/سڕینەوەی پۆلی بەرهەم',
                  color: Colors.brown,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const AdminCategoriesScreen(),
                      ),
                    );
                  },
                ),
                'stats': _AdminMenuCard(
                  icon: Icons.bar_chart_rounded,
                  title: 'ئامار',
                  subtitle: 'فرۆشتن و داهات',
                  color: Colors.orange,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const AdminStatsScreen(),
                      ),
                    );
                  },
                ),
                'banners': _AdminMenuCard(
                  icon: Icons.campaign_rounded,
                  title: 'ڕیکلامەکان',
                  subtitle: 'کۆنترۆڵی بۆردی سەرەوەی Home',
                  color: Colors.pinkAccent,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const AdminBannersScreen(),
                      ),
                    );
                  },
                ),
                'coupons': _AdminMenuCard(
                  icon: Icons.local_offer_rounded,
                  title: 'کۆپۆنەکان',
                  subtitle: 'دروستکردن و ڕێکخستنی کۆدی داشکاندن',
                  color: Colors.deepPurple,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const AdminCouponsScreen(),
                      ),
                    );
                  },
                ),
                'notifications': _AdminMenuCard(
                  icon: Icons.notifications_active_rounded,
                  title: 'ڕاگەیاندنەکان',
                  subtitle: 'ناردنی ڕاگەیاندن بۆ هەموو بەکارهێنەران',
                  color: Colors.indigo,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const AdminSendNotificationScreen(),
                      ),
                    );
                  },
                ),
                'requests': StreamBuilder<int>(
                  stream: pendingFileRequestsCountStream(),
                  builder: (context, requestsSnapshot) {
                    return _AdminMenuCard(
                      icon: Icons.edit_document,
                      title: 'داواکاریا فایلان',
                      subtitle: 'داواکاری تایبەتی قوتابیان',
                      color: Colors.cyan,
                      badgeCount: requestsSnapshot.data ?? 0,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const AdminFileRequestsScreen(),
                          ),
                        );
                      },
                    );
                  },
                ),
              };

              final visibleCards = [
                for (final key in kAdminRoleKeys)
                  if (adminCanAccess(roles, key)) allCards[key]!,
                if (owner)
                  _AdminMenuCard(
                    icon: Icons.admin_panel_settings_rounded,
                    title: 'ئەدمینەکان',
                    subtitle: 'ڕۆڵ و دەستڕاگەیشتنی ئەدمینەکان',
                    color: Colors.brown,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const AdminManageAdminsScreen(),
                        ),
                      );
                    },
                  ),
              ];

              return GridView.count(
                padding: const EdgeInsets.all(18),
                crossAxisCount: 2,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: 1.05,
                children: visibleCards,
              );
            },
          );
        },
      ),
    );
  }
}

class _AdminMenuCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;
  final int? badgeCount;

  const _AdminMenuCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
    this.badgeCount,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: cardSurfaceColor,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: cardBorderColor),
            boxShadow: softShadow(opacity: 0.05, blur: 14),
          ),
          padding: const EdgeInsets.all(16),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: color, size: 24),
                  ),
                  const Spacer(),
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15.5,
                      color: darkText,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: secondaryText,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
              if (badgeCount != null && badgeCount! > 0)
                Positioned(
                  top: -4,
                  left: -4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    constraints: const BoxConstraints(minWidth: 22),
                    decoration: BoxDecoration(
                      color: errorColor,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: softShadow(opacity: 0.15, blur: 6),
                    ),
                    child: Text(
                      badgeCount! > 99 ? '99+' : '$badgeCount',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// ADMIN: ADD PRODUCT
// ============================================================

class AdminAddProductScreen extends StatefulWidget {
  const AdminAddProductScreen({super.key});

  @override
  State<AdminAddProductScreen> createState() =>
      _AdminAddProductScreenState();
}

class _AdminAddProductScreenState extends State<AdminAddProductScreen> {
  bool isSubmitting = false;
  bool isFree = false;
  bool showOnHome = true;
  final titleController = TextEditingController();
  final descriptionController = TextEditingController();
  final authorController = TextEditingController();
  final priceController = TextEditingController();
  final oldPriceController = TextEditingController();

  String? selectedCategoryId;
  String selectedLanguage = 'کوردی';
  List<Category> categoriesCache = [];
  File? coverImage;
  File? pdfFile;
  String? pdfFileName;
  File? videoFile;
  String? videoFileName;
  File? documentFile;
  String? documentFileName;
  bool isPickingFile = false;

  @override
  void dispose() {
    titleController.dispose();
    descriptionController.dispose();
    authorController.dispose();
    priceController.dispose();
    oldPriceController.dispose();
    super.dispose();
  }

  Future<void> _pickCover() async {
    if (isPickingFile) return;
    isPickingFile = true;

    try {
      final picker = ImagePicker();
      final XFile? picked = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1400,
      );
      if (picked == null) return;
      if (!mounted) return;

      // ڕێژەی 4:5 هەمان ڕێژەی ڕاستەقینەی کارتی بەرهەمەکەیە لە Home
      // (172x215)، بۆ ئەوەی کاڤەرەکە بە تەواوی دەردەکەوێت بەبێ
      // بڕینێکی زیادە لای چەپ/ڕاست.
      final cropped = await cropImageWithRatio(
        picked.path,
        ratioX: 4,
        ratioY: 5,
        title: 'دیاریکردنی بەشی وێنە',
      );
      if (cropped == null || !mounted) return;

      setState(() => coverImage = cropped);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('نەتوانرا وێنەکە هەڵبژێردرێت، تکایە دووبارە هەوڵبدەرەوە.'),
        ),
      );
    } finally {
      isPickingFile = false;
    }
  }

  Future<void> _pickPdf() async {
    if (isPickingFile) return;
    isPickingFile = true;

    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );
      if (result.isEmpty || result.single.path == null) return;
      if (!mounted) return;
      setState(() {
        pdfFile = File(result.single.path!);
        pdfFileName = result.single.name;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('نەتوانرا PDF هەڵبژێردرێت، تکایە دووبارە هەوڵبدەرەوە.'),
        ),
      );
    } finally {
      isPickingFile = false;
    }
  }

  /// هەڵبژاردنی ڤیدیۆیەکی کورتی پرێڤیو (ئارەزوومەندانە) — بۆ
  /// پیشاندانی ئەنیمەیشنی تێمپلەیتەکان پێش کڕین.
  Future<void> _pickVideo() async {
    if (isPickingFile) return;
    isPickingFile = true;

    try {
      final result = await FilePicker.pickFiles(
        type: FileType.video,
      );
      if (result.isEmpty || result.single.path == null) return;
      if (!mounted) return;
      setState(() {
        videoFile = File(result.single.path!);
        videoFileName = result.single.name;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('نەتوانرا ڤیدیۆکە هەڵبژێردرێت، تکایە دووبارە هەوڵبدەرەوە.'),
        ),
      );
    } finally {
      isPickingFile = false;
    }
  }

  /// هەڵبژاردنی فایلی دۆکیومێنتی ڕاستەقینە (Word/PowerPoint/Excel/
  /// zip هتد) کە بەکارهێنەر دوای کڕین دەیگرێت و دەتوانێت دەستکاری
  /// بکات — جیاوازە لە فایلی PDF کە تەنها بۆ بینینە.
  Future<void> _pickDocument() async {
    if (isPickingFile) return;
    isPickingFile = true;

    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'doc',
          'docx',
          'ppt',
          'pptx',
          'xls',
          'xlsx',
          'zip',
          'rar',
          'key',
          'psd',
          'ai',
        ],
      );
      if (result.isEmpty || result.single.path == null) return;
      if (!mounted) return;
      setState(() {
        documentFile = File(result.single.path!);
        documentFileName = result.single.name;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('نەتوانرا دۆکیومێنتەکە هەڵبژێردرێت، تکایە دووبارە هەوڵبدەرەوە.'),
        ),
      );
    } finally {
      isPickingFile = false;
    }
  }

  Future<void> _submit() async {
    final title = titleController.text.trim();
    final priceText = priceController.text.trim();

    Category? selectedCategory;
    for (final c in categoriesCache) {
      if (c.id == selectedCategoryId) {
        selectedCategory = c;
        break;
      }
    }

    if (title.isEmpty || selectedCategory == null || priceText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'تکایە ناونیشان، پۆل و نرخ پڕبکەرەوە.',
          ),
        ),
      );
      return;
    }

    final price = double.tryParse(priceText);
    if (price == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('نرخ دەبێت ژمارە بێت.')),
      );
      return;
    }

    setState(() => isSubmitting = true);

    try {
      final docRef = FirebaseFirestore.instance.collection('products').doc();

      String? coverUrl;
      if (coverImage != null) {
        coverUrl = await uploadToSupabase(
          bucket: 'covers',
          path: '${docRef.id}.jpg',
          file: coverImage!,
        );
      }

      String? uploadedPdfUrl;
      if (pdfFile != null) {
        uploadedPdfUrl = await uploadToSupabase(
          bucket: 'pdfs',
          path: '${docRef.id}.pdf',
          file: pdfFile!,
        );
      }

      String? uploadedVideoUrl;
      if (videoFile != null) {
        final ext = videoFileName?.split('.').last ?? 'mp4';
        uploadedVideoUrl = await uploadToSupabase(
          bucket: 'preview-videos',
          path: '${docRef.id}.$ext',
          file: videoFile!,
        );
      }

      String? uploadedDocumentUrl;
      if (documentFile != null) {
        final ext = documentFileName?.split('.').last ?? 'zip';
        uploadedDocumentUrl = await uploadToSupabase(
          bucket: 'documents',
          path: '${docRef.id}.$ext',
          file: documentFile!,
        );
      }

      final oldPriceText = oldPriceController.text.trim();
      final oldPrice = oldPriceText.isEmpty
          ? price
          : (double.tryParse(oldPriceText) ?? price);

      final product = Product(
        id: docRef.id,
        title: title,
        category: selectedCategory.title,
        description: descriptionController.text.trim(),
        author: authorController.text.trim().isEmpty
            ? 'ZNAR Academy'
            : authorController.text.trim(),
        rating: 0,
        reviews: 0,
        oldPrice: oldPrice,
        price: price,
        icon: selectedCategory.icon,
        color: selectedCategory.color,
        pdfUrl: uploadedPdfUrl,
        coverImageUrl: coverUrl,
        previewVideoUrl: uploadedVideoUrl,
        documentUrl: uploadedDocumentUrl,
        documentFileName: documentFile != null ? documentFileName : null,
        createdAt: DateTime.now(),
        language: selectedLanguage,
        showOnHome: showOnHome,
      );

      await docRef.set(product.toMap());

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('بەرهەمەکە بە سەرکەوتوویی زیادکرا ✅')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('هەڵەیەک ڕوویدا: $e')),
      );
    } finally {
      if (mounted) setState(() => isSubmitting = false);
    }
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: cardSurfaceColor,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(title: const Text('زیادکردنی بەرهەمی نوێ')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // COVER PICKER
              GestureDetector(
                onTap: _pickCover,
                child: Container(
                  height: 160,
                  width: double.infinity,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: coverImage == null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.image_outlined,
                                size: 34,
                                color: secondaryText,
                              ),
                              SizedBox(height: 6),
                              Text(
                                'کرتە بکە بۆ زیادکردنی وێنەی بەرگ',
                                style: TextStyle(color: secondaryText),
                              ),
                            ],
                          ),
                        )
                      : Image.file(coverImage!, fit: BoxFit.cover),
                ),
              ),

              const SizedBox(height: 18),

              TextField(
                controller: titleController,
                decoration: _inputDecoration('ناونیشانی بەرهەم *'),
              ),
              const SizedBox(height: 14),

              StreamBuilder<List<Category>>(
                stream: categoriesStream(),
                builder: (context, snapshot) {
                  final categories = snapshot.data ?? sampleCategories;
                  categoriesCache = categories;

                  return DropdownButtonFormField<String>(
                    initialValue:
                        categories.any((c) => c.id == selectedCategoryId)
                            ? selectedCategoryId
                            : null,
                    decoration: _inputDecoration('پۆل *'),
                    items: categories
                        .map(
                          (c) => DropdownMenuItem(
                            value: c.id,
                            child: Text(c.title),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      setState(() => selectedCategoryId = value);
                    },
                  );
                },
              ),
              const SizedBox(height: 14),

              DropdownButtonFormField<String>(
                initialValue: selectedLanguage,
                decoration: _inputDecoration('زمانی ناوەڕۆک *'),
                items: productLanguages
                    .map(
                      (lang) => DropdownMenuItem(
                        value: lang,
                        child: Text(lang),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => selectedLanguage = value);
                },
              ),
              const SizedBox(height: 14),

              TextField(
                controller: descriptionController,
                maxLines: 4,
                decoration: _inputDecoration('وەسف'),
              ),
              const SizedBox(height: 14),

              TextField(
                controller: authorController,
                decoration: _inputDecoration('نووسەر (ئارەزوومەندانە)'),
              ),
              const SizedBox(height: 14),

              CheckboxListTile(
                value: isFree,
                onChanged: (value) {
                  setState(() {
                    isFree = value ?? false;
                    if (isFree) {
                      priceController.text = '0';
                    } else if (priceController.text == '0') {
                      priceController.clear();
                    }
                  });
                },
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: const Text('ئەم بەرهەمە خۆڕاییە (بێ نرخ)'),
              ),
              const SizedBox(height: 6),

              CheckboxListTile(
                value: showOnHome,
                onChanged: (value) {
                  setState(() => showOnHome = value ?? true);
                },
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: const Text('پیشاندان لە پەڕەی سەرەکی (Home)'),
                subtitle: Text(
                  showOnHome
                      ? 'لە بەشەکانی نوێ/باو/داشکاندنی سەرەکیدا دەردەکەوێت'
                      : 'تەنها لەناو پەڕەی کەتەگۆری و گەڕان دەردەکەوێت',
                  style: TextStyle(color: secondaryText, fontSize: 12),
                ),
              ),
              const SizedBox(height: 6),

              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: priceController,
                      enabled: !isFree,
                      keyboardType: TextInputType.number,
                      decoration: _inputDecoration('نرخ (IQD) *'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: oldPriceController,
                      enabled: !isFree,
                      keyboardType: TextInputType.number,
                      decoration:
                          _inputDecoration('نرخی کۆن (ئارەزوومەندانە)'),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 20),

              const Text(
                'فایلی PDF',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 8),

              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: _pickPdf,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: cardSurfaceColor,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.picture_as_pdf_outlined,
                        color: primaryBlue,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          pdfFileName ?? 'کرتە بکە بۆ هەڵبژاردنی PDF',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: pdfFileName == null
                                ? secondaryText
                                : darkText,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              const Text(
                'ڤیدیۆی پرێڤیو (ئارەزوومەندانە — بۆ ئەنیمەیشن)',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 8),

              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: _pickVideo,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: cardSurfaceColor,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.videocam_outlined,
                        color: primaryBlue,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          videoFileName ??
                              'کرتە بکە بۆ هەڵبژاردنی ڤیدیۆی پرێڤیو',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: videoFileName == null
                                ? secondaryText
                                : darkText,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              const Text(
                'فایلی دۆکیومێنتی ڕاستەقینە (ئارەزوومەندانە — Word/PowerPoint/Excel/ZIP)',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 4),
              Text(
                'ئەم فایلە جیاوازە لە PDF — کاڕهێنەر دوای کڕین دایدەگرێت و دەتوانێت دەستکاری بکات.',
                style: TextStyle(color: secondaryText, fontSize: 12),
              ),
              const SizedBox(height: 8),

              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: _pickDocument,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: cardSurfaceColor,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.folder_zip_outlined,
                        color: primaryBlue,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          documentFileName ??
                              'کرتە بکە بۆ هەڵبژاردنی دۆکیومێنت',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: documentFileName == null
                                ? secondaryText
                                : darkText,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 30),

              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: isSubmitting ? null : _submit,
                  icon: isSubmitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.add_circle_outline),
                  label: const Text(
                    'زیادکردنی بەرهەم',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryBlue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// ADMIN PRODUCTS (list + edit existing products, incl. cover)
// ============================================================

class AdminProductsScreen extends StatelessWidget {
  const AdminProductsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(title: const Text('بەڕێوەبردنی بەرهەمەکان')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const AdminAddProductScreen(),
            ),
          );
        },
        backgroundColor: primaryBlue,
        icon: const Icon(Icons.add),
        label: const Text('بەرهەمی نوێ'),
      ),
      body: AppRefresh(
        queries: [_productsRef()],
        child: StreamBuilder<List<Product>>(
        stream: productsStream(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final products = snapshot.data ?? [];

          if (products.isEmpty) {
            return const EmptyState(
              icon: Icons.menu_book_outlined,
              message: 'هیچ بەرهەمێک نییە.',
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: products.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final product = products[index];

              return Opacity(
                opacity: product.isActive ? 1 : 0.5,
                child: Container(
                padding: const EdgeInsets.all(12),
                decoration: softCardDecoration(),
                child: Row(
                  children: [
                    ProductThumbnail(
                      product: product,
                      width: 56,
                      height: 56,
                      borderRadius: 12,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            product.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 3),
                          if (!product.isFree)
                            Text(
                              formatIQD(product.price),
                              style: const TextStyle(
                                color: primaryBlue,
                                fontWeight: FontWeight.w600,
                                fontSize: 12.5,
                              ),
                            ),
                          const SizedBox(height: 3),
                          Text(
                            product.isActive ? 'چالاکە ✅' : 'شاراوەیە 🚫',
                            style: TextStyle(
                              color: product.isActive
                                  ? successColor
                                  : secondaryText,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: product.isActive,
                      activeThumbColor: successColor,
                      onChanged: (value) {
                        FirebaseFirestore.instance
                            .collection('products')
                            .doc(product.id)
                            .update({'isActive': value});
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, color: primaryBlue),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                AdminEditProductScreen(product: product),
                          ),
                        );
                      },
                    ),
                  ],
                ),
                ),
              );
            },
          );
        },
      )),
    );
  }
}

class AdminEditProductScreen extends StatefulWidget {
  final Product product;

  const AdminEditProductScreen({super.key, required this.product});

  @override
  State<AdminEditProductScreen> createState() =>
      _AdminEditProductScreenState();
}

class _AdminEditProductScreenState extends State<AdminEditProductScreen> {
  late final titleController =
      TextEditingController(text: widget.product.title);
  late final descriptionController =
      TextEditingController(text: widget.product.description);
  late final authorController =
      TextEditingController(text: widget.product.author);
  late final priceController =
      TextEditingController(text: widget.product.price.toStringAsFixed(0));
  late final oldPriceController = TextEditingController(
    text: widget.product.oldPrice.toStringAsFixed(0),
  );

  String? selectedCategoryId;
  late String selectedLanguage = widget.product.language;
  List<Category> categoriesCache = [];

  File? newCoverImage;
  String? currentCoverUrl;
  File? documentFile;
  String? documentFileName;
  String? currentDocumentFileName;
  bool isSubmitting = false;
  bool isPickingFile = false;
  late bool showOnHome = widget.product.showOnHome;

  @override
  void initState() {
    super.initState();
    currentCoverUrl = widget.product.coverImageUrl;
    currentDocumentFileName = widget.product.documentFileName;
  }

  @override
  void dispose() {
    titleController.dispose();
    descriptionController.dispose();
    authorController.dispose();
    priceController.dispose();
    oldPriceController.dispose();
    super.dispose();
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: cardSurfaceColor,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    );
  }

  Future<void> _pickCover() async {
    if (isPickingFile) return;
    isPickingFile = true;

    try {
      final picker = ImagePicker();
      final XFile? picked = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1400,
      );
      if (picked == null) return;
      if (!mounted) return;

      // ڕێژەی 4:5 هەمان ڕێژەی ڕاستەقینەی کارتی بەرهەمەکەیە لە Home.
      final cropped = await cropImageWithRatio(
        picked.path,
        ratioX: 4,
        ratioY: 5,
        title: 'دیاریکردنی بەشی وێنە',
      );
      if (cropped == null || !mounted) return;

      setState(() => newCoverImage = cropped);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('نەتوانرا وێنەکە هەڵبژێردرێت، تکایە دووبارە هەوڵبدەرەوە.'),
        ),
      );
    } finally {
      isPickingFile = false;
    }
  }

  Future<void> _pickDocument() async {
    if (isPickingFile) return;
    isPickingFile = true;

    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'doc',
          'docx',
          'ppt',
          'pptx',
          'xls',
          'xlsx',
          'zip',
          'rar',
          'key',
          'psd',
          'ai',
        ],
      );
      if (result.isEmpty || result.single.path == null) return;
      if (!mounted) return;
      setState(() {
        documentFile = File(result.single.path!);
        documentFileName = result.single.name;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('نەتوانرا دۆکیومێنتەکە هەڵبژێردرێت، تکایە دووبارە هەوڵبدەرەوە.'),
        ),
      );
    } finally {
      isPickingFile = false;
    }
  }

  Future<void> _save() async {
    final title = titleController.text.trim();
    final priceText = priceController.text.trim();

    Category? selectedCategory;
    for (final c in categoriesCache) {
      if (c.id == selectedCategoryId) {
        selectedCategory = c;
        break;
      }
    }

    if (title.isEmpty || priceText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تکایە ناونیشان و نرخ پڕبکەرەوە.')),
      );
      return;
    }

    final price = double.tryParse(priceText);
    if (price == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('نرخ دەبێت ژمارە بێت.')),
      );
      return;
    }

    setState(() => isSubmitting = true);

    try {
      String? coverUrl = currentCoverUrl;
      if (newCoverImage != null) {
        // نوێکردنەوەی هەمان فایل لە Supabase (overwrite)
        coverUrl = await uploadToSupabase(
          bucket: 'covers',
          path: '${widget.product.id}.jpg',
          file: newCoverImage!,
        );
      }

      String? documentUrl;
      if (documentFile != null) {
        final ext = documentFileName?.split('.').last ?? 'zip';
        documentUrl = await uploadToSupabase(
          bucket: 'documents',
          path: '${widget.product.id}.$ext',
          file: documentFile!,
        );
      }

      final oldPriceText = oldPriceController.text.trim();
      final oldPrice = oldPriceText.isEmpty
          ? price
          : (double.tryParse(oldPriceText) ?? price);

      final updateData = <String, dynamic>{
        'title': title,
        'description': descriptionController.text.trim(),
        'author': authorController.text.trim().isEmpty
            ? 'ZNAR Academy'
            : authorController.text.trim(),
        'price': price,
        'oldPrice': oldPrice,
        'language': selectedLanguage,
        'showOnHome': showOnHome,
        if (coverUrl != null) 'coverImageUrl': coverUrl,
        if (documentUrl != null) 'documentUrl': documentUrl,
        if (documentFileName != null) 'documentFileName': documentFileName,
      };

      if (selectedCategory != null) {
        updateData['category'] = selectedCategory.title;
        updateData['iconCodePoint'] = selectedCategory.icon.codePoint;
        updateData['colorValue'] = selectedCategory.color.toARGB32();
      }

      await FirebaseFirestore.instance
          .collection('products')
          .doc(widget.product.id)
          .update(updateData);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('بەرهەمەکە نوێکرایەوە ✅')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('هەڵەیەک ڕوویدا: $e')),
      );
    } finally {
      if (mounted) setState(() => isSubmitting = false);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('سڕینەوەی بەرهەم'),
        content: const Text('دڵنیایت لە سڕینەوەی ئەم بەرهەمە؟ ناگەڕێتەوە.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('پاشگەزبوونەوە'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('سڕینەوە', style: TextStyle(color: errorColor)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await FirebaseFirestore.instance
          .collection('products')
          .doc(widget.product.id)
          .delete();
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('هەڵە: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: const Text('دەستکاریکردنی بەرهەم'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline, color: errorColor),
            onPressed: _delete,
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'کاڤەری بەرهەم',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              const SizedBox(height: 8),

              // COVER PICKER (پیشاندانی کاڤەری ئێستا یان نوێ)
              GestureDetector(
                onTap: _pickCover,
                child: Container(
                  height: 190,
                  width: double.infinity,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: cardSurfaceColor,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (newCoverImage != null)
                        Image.file(newCoverImage!, fit: BoxFit.cover)
                      else if (currentCoverUrl != null)
                        Image.network(
                          currentCoverUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Center(
                            child: Icon(
                              widget.product.icon,
                              size: 46,
                              color: widget.product.color,
                            ),
                          ),
                        )
                      else
                        Center(
                          child: Icon(
                            widget.product.icon,
                            size: 46,
                            color: widget.product.color,
                          ),
                        ),
                      Positioned(
                        bottom: 8,
                        right: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.edit, color: Colors.white, size: 14),
                              SizedBox(width: 6),
                              Text(
                                'گۆڕینی کاڤەر',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              const Text(
                'فایلی دۆکیومێنتی ڕاستەقینە (ئارەزوومەندانە — Word/PowerPoint/Excel/ZIP)',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 4),
              Text(
                'ئەم فایلە جیاوازە لە PDF — کاڕهێنەر دوای کڕین دایدەگرێت و دەتوانێت دەستکاری بکات.'
                '${currentDocumentFileName != null ? '\nفایلی ئێستا: $currentDocumentFileName' : ''}',
                style: TextStyle(color: secondaryText, fontSize: 12),
              ),
              const SizedBox(height: 8),

              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: _pickDocument,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: cardSurfaceColor,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.folder_zip_outlined,
                        color: primaryBlue,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          documentFileName ??
                              (currentDocumentFileName ??
                                  'کرتە بکە بۆ هەڵبژاردنی دۆکیومێنت'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: (documentFileName == null &&
                                    currentDocumentFileName == null)
                                ? secondaryText
                                : darkText,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              TextField(
                controller: titleController,
                decoration: _inputDecoration('ناونیشانی بەرهەم *'),
              ),
              const SizedBox(height: 14),

              StreamBuilder<List<Category>>(
                stream: categoriesStream(),
                builder: (context, snapshot) {
                  final categories = snapshot.data ?? sampleCategories;
                  categoriesCache = categories;

                  selectedCategoryId ??= categories
                      .firstWhere(
                        (c) => c.title == widget.product.category,
                        orElse: () => categories.first,
                      )
                      .id;

                  return DropdownButtonFormField<String>(
                    initialValue:
                        categories.any((c) => c.id == selectedCategoryId)
                            ? selectedCategoryId
                            : null,
                    decoration: _inputDecoration('پۆل'),
                    items: categories
                        .map(
                          (c) => DropdownMenuItem(
                            value: c.id,
                            child: Text(c.title),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      setState(() => selectedCategoryId = value);
                    },
                  );
                },
              ),
              const SizedBox(height: 14),

              DropdownButtonFormField<String>(
                initialValue: selectedLanguage,
                decoration: _inputDecoration('زمانی ناوەڕۆک'),
                items: productLanguages
                    .map(
                      (lang) => DropdownMenuItem(
                        value: lang,
                        child: Text(lang),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => selectedLanguage = value);
                },
              ),
              const SizedBox(height: 14),

              CheckboxListTile(
                value: showOnHome,
                onChanged: (value) {
                  setState(() => showOnHome = value ?? true);
                },
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: const Text('پیشاندان لە پەڕەی سەرەکی (Home)'),
                subtitle: Text(
                  showOnHome
                      ? 'لە بەشەکانی نوێ/باو/داشکاندنی سەرەکیدا دەردەکەوێت'
                      : 'تەنها لەناو پەڕەی کەتەگۆری و گەڕان دەردەکەوێت',
                  style: TextStyle(color: secondaryText, fontSize: 12),
                ),
              ),
              const SizedBox(height: 14),

              TextField(
                controller: descriptionController,
                maxLines: 4,
                decoration: _inputDecoration('وەسف'),
              ),
              const SizedBox(height: 14),

              TextField(
                controller: authorController,
                decoration: _inputDecoration('نووسەر'),
              ),
              const SizedBox(height: 14),

              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: priceController,
                      keyboardType: TextInputType.number,
                      decoration: _inputDecoration('نرخ (IQD) *'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: oldPriceController,
                      keyboardType: TextInputType.number,
                      decoration: _inputDecoration('نرخی کۆن'),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 30),

              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: isSubmitting ? null : _save,
                  icon: isSubmitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.save_outlined),
                  label: const Text(
                    'خەزنکردنی گۆڕانکارییەکان',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryBlue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// ADMIN ORDERS
// ============================================================

// ============================================================
// ADMIN: FILE REQUESTS (داواکاریا فایلان)
// ============================================================

class AdminFileRequestsScreen extends StatelessWidget {
  const AdminFileRequestsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(title: const Text('داواکاریا فایلان')),
      body: AppRefresh(
        queries: [_fileRequestsRef()],
        child: StreamBuilder<List<Map<String, dynamic>>>(
        stream: allFileRequestsStream(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final items = snapshot.data ?? [];

          if (items.isEmpty) {
            return const EmptyState(
              icon: Icons.edit_document,
              message: 'هیچ داواکارییەکی قوتابیان نییە.',
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(18),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final fulfilled = item['status'] == 'fulfilled';
              final createdAt = item['createdAt'];
              final dt = createdAt is Timestamp ? createdAt.toDate() : null;

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(14),
                decoration: softCardDecoration(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            item['title'] as String? ?? '',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: darkText,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: (fulfilled ? successColor : Colors.orange)
                                .withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            fulfilled ? 'ئامادەکرا' : 'چاوەڕوان',
                            style: TextStyle(
                              color:
                                  fulfilled ? successColor : Colors.orange,
                              fontWeight: FontWeight.bold,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if ((item['description'] as String? ?? '').isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        item['description'] as String,
                        style: TextStyle(
                          color: secondaryText,
                          fontSize: 13,
                          height: 1.5,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      item['userEmail'] as String? ?? '',
                      textDirection: TextDirection.ltr,
                      style: TextStyle(color: secondaryText, fontSize: 11.5),
                    ),
                    if (dt != null)
                      Text(
                        '${dt.year}/${dt.month}/${dt.day}',
                        style: TextStyle(color: secondaryText, fontSize: 11),
                      ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      height: 42,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          setFileRequestFulfilled(
                            item['id'] as String,
                            !fulfilled,
                          );
                        },
                        icon: Icon(
                          fulfilled
                              ? Icons.replay_rounded
                              : Icons.check_circle_outline,
                        ),
                        label: Text(
                          fulfilled
                              ? 'گەڕاندنەوە بۆ چاوەڕوان'
                              : 'نیشانەکردن وەک ئامادەکراو',
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor:
                              fulfilled ? Colors.orange : successColor,
                          side: BorderSide(
                            color: fulfilled ? Colors.orange : successColor,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      )),
    );
  }
}

class AdminOrdersScreen extends StatelessWidget {
  const AdminOrdersScreen({super.key});

  Future<void> _updateStatus(
    BuildContext context,
    Map<String, dynamic> order,
    String newStatus,
  ) async {
    try {
      await FirebaseFirestore.instance
          .collection('orders')
          .doc(order['id'] as String)
          .update({'status': newStatus});

      if (newStatus == 'approved') {
        await grantLibraryForOrderIfNeeded({
          ...order,
          'status': 'approved',
        });
      }

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            newStatus == 'approved'
                ? 'داواکارییەکە پشتڕاستکرایەوە ✅'
                : 'داواکارییەکە ڕەتکرایەوە ❌',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('هەڵەیەک ڕوویدا: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'approved':
        return successColor;
      case 'rejected':
        return errorColor;
      default:
        return accentGold;
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'approved':
        return 'پشتڕاستکراوە';
      case 'rejected':
        return 'ڕەتکراوە';
      default:
        return 'چاوەڕوانی پشتڕاستکردنەوە';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(title: const Text('داواکارییەکان')),
      body: AppRefresh(
        queries: [
          FirebaseFirestore.instance
              .collection('orders')
              .orderBy('createdAt', descending: true),
        ],
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('orders')
            .orderBy('createdAt', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snapshot.data?.docs ?? [];

          if (docs.isEmpty) {
            return const EmptyState(
              icon: Icons.receipt_long_outlined,
              message: 'هیچ داواکارییەک نییە.',
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final order = {...docs[index].data(), 'id': docs[index].id};
              final status = order['status'] as String? ?? 'pending';
              final items = (order['items'] as List<dynamic>? ?? []);
              final receiptUrl = order['receiptUrl'] as String?;

              return Container(
                margin: const EdgeInsets.only(bottom: 14),
                padding: const EdgeInsets.all(14),
                decoration: softCardDecoration(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            order['userEmail'] as String? ?? '',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                            textDirection: TextDirection.ltr,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: _statusColor(status).withOpacity(0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            _statusLabel(status),
                            style: TextStyle(
                              color: _statusColor(status),
                              fontSize: 11.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    for (final item in items)
                      Text(
                        '• ${(item as Map)['title']} — \$${item['price']}',
                        style: TextStyle(
                          fontSize: 13,
                          color: secondaryText,
                        ),
                      ),
                    const SizedBox(height: 6),
                    Text(
                      'کۆی گشتی: ${order['totalIQD']} د.ع',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: primaryBlue,
                      ),
                    ),
                    if (receiptUrl != null) ...[
                      const SizedBox(height: 10),
                      GestureDetector(
                        onTap: () {
                          showDialog(
                            context: context,
                            builder: (_) => Dialog(
                              child: Image.network(receiptUrl),
                            ),
                          );
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.network(
                            receiptUrl,
                            height: 140,
                            width: double.infinity,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              height: 140,
                              color: Colors.grey.shade200,
                              alignment: Alignment.center,
                              child: const Icon(Icons.broken_image_outlined),
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (status == 'pending') ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () =>
                                  _updateStatus(context, order, 'rejected'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: errorColor,
                                side: const BorderSide(color: errorColor),
                              ),
                              child: const Text('ڕەتکردنەوە'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () =>
                                  _updateStatus(context, order, 'approved'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: successColor,
                                foregroundColor: Colors.white,
                              ),
                              child: const Text('پشتڕاستکردنەوە'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              );
            },
          );
        },
      )),
    );
  }
}

// ============================================================
// ADMIN USERS
// ============================================================

// ============================================================
// ADMIN: MANAGE ADMINS (تەنها بۆ owner)
// ============================================================

class AdminManageAdminsScreen extends StatelessWidget {
  const AdminManageAdminsScreen({super.key});

  void _openEditor(BuildContext context, {String? uid, List<String>? roles}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: cardSurfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => _AdminEditorSheet(uid: uid, initialRoles: roles),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(title: const Text('ئەدمینەکان')),
      floatingActionButton: FloatingActionButton(
        backgroundColor: primaryBlue,
        onPressed: () => _openEditor(context),
        child: const Icon(Icons.person_add_alt_1_rounded, color: Colors.white),
      ),
      body: AppRefresh(
        queries: [FirebaseFirestore.instance.collection('admins')],
        child: StreamBuilder<List<Map<String, dynamic>>>(
        stream: allAdminsStream(),
        builder: (context, snapshot) {
          final admins = snapshot.data ?? [];

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (admins.isEmpty) {
            return const EmptyState(
              icon: Icons.admin_panel_settings_outlined,
              message: 'هیچ ئەدمینێک نییە.',
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
            itemCount: admins.length,
            itemBuilder: (context, index) {
              final admin = admins[index];
              final uid = admin['uid'] as String;
              List<String> roles = [];
              if (admin['roles'] is List) {
                roles = (admin['roles'] as List).map((e) => e.toString()).toList();
              } else if (admin['role'] is String) {
                roles = [admin['role'] as String];
              }
              final owner = adminIsOwner(roles);

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(14),
                decoration: softCardDecoration(),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: primaryBlue.withValues(alpha: 0.1),
                      child: Icon(
                        owner
                            ? Icons.star_rounded
                            : Icons.person_outline_rounded,
                        color: primaryBlue,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            uid,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textDirection: TextDirection.ltr,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12.5,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            owner
                                ? 'دەستڕاگەیشتنی تەواو (Owner)'
                                : roles
                                    .map((r) => kAdminRoleLabels[r] ?? r)
                                    .join('، '),
                            style: TextStyle(
                              color: secondaryText,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () =>
                          _openEditor(context, uid: uid, roles: roles),
                      icon: const Icon(Icons.edit_outlined, color: primaryBlue),
                    ),
                    IconButton(
                      onPressed: () async {
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: const Text('سڕینەوەی ئەدمین'),
                            content: Text(
                              'دڵنیایت لە سڕینەوەی ئەم ئەدمینە؟\n$uid',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('پاشگەزبوونەوە'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text(
                                  'سڕینەوە',
                                  style: TextStyle(color: Colors.redAccent),
                                ),
                              ),
                            ],
                          ),
                        );
                        if (confirm == true) {
                          await removeAdmin(uid);
                        }
                      },
                      icon: const Icon(Icons.delete_outline,
                          color: Colors.redAccent),
                    ),
                  ],
                ),
              );
            },
          );
        },
      )),
    );
  }
}

class _AdminEditorSheet extends StatefulWidget {
  final String? uid;
  final List<String>? initialRoles;

  const _AdminEditorSheet({this.uid, this.initialRoles});

  @override
  State<_AdminEditorSheet> createState() => _AdminEditorSheetState();
}

class _AdminEditorSheetState extends State<_AdminEditorSheet> {
  final uidController = TextEditingController();
  Set<String> selectedRoles = {};
  bool isOwnerToggle = false;
  bool isSaving = false;

  @override
  void initState() {
    super.initState();
    if (widget.uid != null) uidController.text = widget.uid!;
    if (widget.initialRoles != null) {
      isOwnerToggle = adminIsOwner(widget.initialRoles!);
      selectedRoles = widget.initialRoles!.toSet();
    }
  }

  @override
  void dispose() {
    uidController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final uid = uidController.text.trim();
    if (uid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تکایە UID ی بەکارهێنەر بنووسە.')),
      );
      return;
    }

    setState(() => isSaving = true);
    try {
      final roles = isOwnerToggle ? <String>['owner'] : selectedRoles.toList();
      await setAdminRoles(uid, roles);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('هەڵەیەک ڕوویدا: $e')),
      );
    } finally {
      if (mounted) setState(() => isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.uid != null;

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isEditing ? 'گۆڕینی ڕۆڵی ئەدمین' : 'زیادکردنی ئەدمینی نوێ',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 17,
                color: darkText,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: uidController,
              enabled: !isEditing,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(
                labelText: 'UID (لە Profile ـی بەکارهێنەر کۆپی بکە)',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: isOwnerToggle,
              activeColor: primaryBlue,
              title: Text(
                'Owner (دەستڕاگەیشتنی تەواو)',
                style: TextStyle(fontWeight: FontWeight.w600, color: darkText),
              ),
              onChanged: (value) => setState(() => isOwnerToggle = value),
            ),
            if (!isOwnerToggle) ...[
              const SizedBox(height: 6),
              Text(
                'یان تەنها ئەم بەشانە دیاری بکە:',
                style: TextStyle(color: secondaryText, fontSize: 13),
              ),
              const SizedBox(height: 6),
              ...kAdminRoleKeys.map((key) {
                return CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  activeColor: primaryBlue,
                  value: selectedRoles.contains(key),
                  title: Text(
                    kAdminRoleLabels[key] ?? key,
                    style: TextStyle(color: darkText),
                  ),
                  onChanged: (checked) {
                    setState(() {
                      if (checked == true) {
                        selectedRoles.add(key);
                      } else {
                        selectedRoles.remove(key);
                      }
                    });
                  },
                );
              }),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: isSaving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryBlue,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: isSaving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('خەزنکردن'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AdminUsersScreen extends StatefulWidget {
  const AdminUsersScreen({super.key});

  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends State<AdminUsersScreen> {
  final searchController = TextEditingController();
  String query = '';

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(title: const Text('بەکارهێنەران')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: TextField(
              controller: searchController,
              onChanged: (value) =>
                  setState(() => query = value.trim().toLowerCase()),
              decoration: InputDecoration(
                hintText: 'گەڕان بە ناو یان ئیمەیل...',
                prefixIcon: const Icon(Icons.search_rounded),
                filled: true,
                fillColor: cardSurfaceColor,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: AppRefresh(
              queries: [
                FirebaseFirestore.instance
                    .collection('users')
                    .orderBy('createdAt', descending: true),
              ],
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .orderBy('createdAt', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                var docs = snapshot.data?.docs ?? [];

                if (query.isNotEmpty) {
                  docs = docs.where((d) {
                    final data = d.data();
                    final name =
                        (data['name'] as String? ?? '').toLowerCase();
                    final email =
                        (data['email'] as String? ?? '').toLowerCase();
                    return name.contains(query) || email.contains(query);
                  }).toList();
                }

                if (docs.isEmpty) {
                  return const EmptyState(
                    icon: Icons.people_outline,
                    message: 'هیچ بەکارهێنەرێک نەدۆزرایەوە.',
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final uid = docs[index].id;
                    final data = docs[index].data();
                    final photoUrl = data['photoUrl'] as String?;
                    final blocked = data['blocked'] as bool? ?? false;

                    return Container(
                      decoration: softCardDecoration(),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(kRadiusMd),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => AdminUserDetailScreen(
                                  uid: uid,
                                  name: data['name'] as String? ?? '—',
                                  email: data['email'] as String? ?? '',
                                  photoUrl: photoUrl,
                                  blocked: blocked,
                                ),
                              ),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 24,
                                  backgroundColor: const Color(0xFFEFF6FF),
                                  backgroundImage: photoUrl != null
                                      ? NetworkImage(photoUrl)
                                      : null,
                                  child: photoUrl == null
                                      ? const Icon(Icons.person,
                                          color: primaryBlue)
                                      : null,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              data['name'] as String? ?? '—',
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                color: darkText,
                                              ),
                                            ),
                                          ),
                                          if (blocked) ...[
                                            const SizedBox(width: 6),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 8,
                                                vertical: 2,
                                              ),
                                              decoration: BoxDecoration(
                                                color: Colors.redAccent
                                                    .withValues(alpha: 0.12),
                                                borderRadius:
                                                    BorderRadius.circular(20),
                                              ),
                                              child: const Text(
                                                'بلۆککراوە',
                                                style: TextStyle(
                                                  color: Colors.redAccent,
                                                  fontSize: 10.5,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                      Text(
                                        data['email'] as String? ?? '',
                                        style: TextStyle(
                                          color: secondaryText,
                                          fontSize: 12.5,
                                        ),
                                        textDirection: TextDirection.ltr,
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(Icons.chevron_right,
                                    color: secondaryText),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            )),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// ADMIN: USER DETAIL (بلۆککردن + مێژووی کڕین)
// ============================================================

class AdminUserDetailScreen extends StatefulWidget {
  final String uid;
  final String name;
  final String email;
  final String? photoUrl;
  final bool blocked;

  const AdminUserDetailScreen({
    super.key,
    required this.uid,
    required this.name,
    required this.email,
    required this.photoUrl,
    required this.blocked,
  });

  @override
  State<AdminUserDetailScreen> createState() => _AdminUserDetailScreenState();
}

class _AdminUserDetailScreenState extends State<AdminUserDetailScreen> {
  late bool blocked = widget.blocked;
  bool isToggling = false;

  Future<void> _toggleBlock() async {
    setState(() => isToggling = true);
    try {
      await toggleUserBlocked(widget.uid, !blocked);
      if (!mounted) return;
      setState(() {
        blocked = !blocked;
        isToggling = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => isToggling = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('هەڵەیەک ڕوویدا: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(title: Text(widget.name)),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: softCardDecoration(),
            child: Column(
              children: [
                CircleAvatar(
                  radius: 36,
                  backgroundColor: const Color(0xFFEFF6FF),
                  backgroundImage: widget.photoUrl != null
                      ? NetworkImage(widget.photoUrl!)
                      : null,
                  child: widget.photoUrl == null
                      ? const Icon(Icons.person, color: primaryBlue, size: 32)
                      : null,
                ),
                const SizedBox(height: 12),
                Text(
                  widget.name,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: darkText,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.email,
                  textDirection: TextDirection.ltr,
                  style: TextStyle(color: secondaryText, fontSize: 13),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton.icon(
                    onPressed: isToggling ? null : _toggleBlock,
                    icon: Icon(
                      blocked
                          ? Icons.lock_open_rounded
                          : Icons.block_rounded,
                    ),
                    label: Text(
                      blocked ? 'لابردنی بلۆک' : 'بلۆککردنی هەژمار',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          blocked ? successColor : Colors.redAccent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Text(
            'مێژووی کڕین',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 15,
              color: darkText,
            ),
          ),
          const SizedBox(height: 10),
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: userOrdersStreamFor(widget.uid),
            builder: (context, snapshot) {
              final orders = snapshot.data ?? [];

              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                );
              }

              if (orders.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    'ئەم بەکارهێنەرە هێشتا هیچ کڕینێکی نییە.',
                    style: TextStyle(color: secondaryText),
                  ),
                );
              }

              return Column(
                children: orders.map((order) {
                  final items = (order['items'] as List<dynamic>? ?? []);
                  final total =
                      (order['totalIQD'] as num?)?.toDouble() ?? 0;
                  final status = order['status'] as String? ?? 'pending';

                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(12),
                    decoration: softCardDecoration(),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                items
                                    .map((i) => (i as Map)['title'].toString())
                                    .join('، '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: darkText,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                formatIQD(total),
                                style: const TextStyle(
                                  color: primaryBlue,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          status == 'approved'
                              ? 'پشتڕاستکراوە'
                              : status == 'rejected'
                                  ? 'ڕەتکراوە'
                                  : 'چاوەڕوان',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.bold,
                            color: status == 'approved'
                                ? successColor
                                : status == 'rejected'
                                    ? Colors.redAccent
                                    : Colors.orange,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

// ============================================================
// ADMIN STATS
// ============================================================

class AdminStatsScreen extends StatefulWidget {
  const AdminStatsScreen({super.key});

  @override
  State<AdminStatsScreen> createState() => _AdminStatsScreenState();
}

class _AdminStatsScreenState extends State<AdminStatsScreen> {
  late Future<Map<String, dynamic>> _statsFuture = _loadStats();

  Future<void> _refresh() async {
    final next = _loadStats();
    setState(() => _statsFuture = next);
    try {
      await next;
    } catch (_) {
      // هەڵەکە لەناو FutureBuilder پیشان دەدرێت.
    }
  }

  Future<Map<String, dynamic>> _loadStats() async {
    final ordersSnap =
        await FirebaseFirestore.instance.collection('orders').get();
    final usersSnap =
        await FirebaseFirestore.instance.collection('users').get();
    final productsSnap =
        await FirebaseFirestore.instance.collection('products').get();

    double totalRevenue = 0;
    int approvedCount = 0;
    int pendingCount = 0;
    int rejectedCount = 0;

    for (final doc in ordersSnap.docs) {
      final data = doc.data();
      final status = data['status'] as String? ?? 'pending';
      if (status == 'approved') {
        approvedCount++;
        totalRevenue += (data['totalIQD'] as num?)?.toDouble() ?? 0;
      } else if (status == 'rejected') {
        rejectedCount++;
      } else {
        pendingCount++;
      }
    }

    return {
      'totalOrders': ordersSnap.docs.length,
      'approvedCount': approvedCount,
      'pendingCount': pendingCount,
      'rejectedCount': rejectedCount,
      'totalRevenue': totalRevenue,
      'usersCount': usersSnap.docs.length,
      'productsCount': productsSnap.docs.length,
    };
  }

  Widget _statCard(String title, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: softCardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 26),
          const SizedBox(height: 10),
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: darkText,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: TextStyle(
              fontSize: 12.5,
              color: secondaryText,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(title: const Text('ئامار')),
      body: AppRefresh(
        onRefresh: _refresh,
        child: FutureBuilder<Map<String, dynamic>>(
        future: _statsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return const EmptyState(
              icon: Icons.error_outline_rounded,
              message: 'هەڵەیەک ڕوویدا. بکێشە خوارەوە بۆ دووبارە هەوڵدان.',
            );
          }

          final stats = snapshot.data!;

          return GridView.count(
            padding: const EdgeInsets.all(18),
            crossAxisCount: 2,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: 1.2,
            children: [
              _statCard(
                'کۆی داهات (پشتڕاستکراو)',
                '${stats['totalRevenue']} د.ع',
                Icons.attach_money,
                successColor,
              ),
              _statCard(
                'کۆی داواکارییەکان',
                '${stats['totalOrders']}',
                Icons.receipt_long_rounded,
                primaryBlue,
              ),
              _statCard(
                'چاوەڕوانی پشتڕاستکردنەوە',
                '${stats['pendingCount']}',
                Icons.hourglass_top_rounded,
                accentGold,
              ),
              _statCard(
                'پشتڕاستکراو',
                '${stats['approvedCount']}',
                Icons.check_circle_outline,
                successColor,
              ),
              _statCard(
                'ڕەتکراوە',
                '${stats['rejectedCount']}',
                Icons.cancel_outlined,
                errorColor,
              ),
              _statCard(
                'کۆی بەکارهێنەران',
                '${stats['usersCount']}',
                Icons.people_alt_rounded,
                Colors.teal,
              ),
              _statCard(
                'کۆی بەرهەمەکان',
                '${stats['productsCount']}',
                Icons.menu_book_rounded,
                secondaryPurple,
              ),
            ],
          );
        },
      )),
    );
  }
}

// ============================================================
// ADMIN BANNERS
// ============================================================

class AdminBannersScreen extends StatefulWidget {
  const AdminBannersScreen({super.key});

  @override
  State<AdminBannersScreen> createState() => _AdminBannersScreenState();
}

class _AdminBannersScreenState extends State<AdminBannersScreen> {
  final titleController = TextEditingController();
  final subtitleController = TextEditingController();
  File? imageFile;
  bool isSubmitting = false;
  int bannerIntervalSeconds = 4;

  @override
  void initState() {
    super.initState();
    getBannerIntervalSeconds().then((seconds) {
      if (mounted) setState(() => bannerIntervalSeconds = seconds);
    });
  }

  // ئەگەر null بوو، فۆرمەکە بۆ زیادکردنی ڕیکلامی نوێیە.
  // ئەگەر ناسنامەیەکی تێدابوو، فۆرمەکە بۆ دەستکاریکردنی
  // ڕیکلامێکی هەیە.
  String? editingId;
  String? existingImageUrl;

  @override
  void dispose() {
    titleController.dispose();
    subtitleController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final XFile? picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 1600,
    );
    if (picked == null) return;

    // ڕێژەی 8:5 هەمان ڕێژەی کارتی ڕیکلامەکەیە لە Home، بۆ ئەوەی
    // وێنەکە بە تەواوی و بەبێ بڕینێکی زیادە دەردەکەوێت.
    final cropped = await cropImageWithRatio(
      picked.path,
      ratioX: 8,
      ratioY: 5,
      title: 'دیاریکردنی بەشی وێنە',
    );
    if (cropped == null) return;

    setState(() => imageFile = cropped);
  }

  void _startEdit(AppBanner banner) {
    setState(() {
      editingId = banner.id;
      titleController.text = banner.title;
      subtitleController.text = banner.subtitle;
      existingImageUrl = banner.imageUrl;
      imageFile = null;
    });
  }

  void _cancelEdit() {
    setState(() {
      editingId = null;
      existingImageUrl = null;
      imageFile = null;
      titleController.clear();
      subtitleController.clear();
    });
  }

  Future<void> _saveBanner() async {
    final title = titleController.text.trim();
    final subtitle = subtitleController.text.trim();

    if (imageFile == null && existingImageUrl == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تکایە وێنەیەک هەڵبژێرە.')),
      );
      return;
    }

    setState(() => isSubmitting = true);

    try {
      final isEditing = editingId != null;
      final docRef = isEditing
          ? FirebaseFirestore.instance.collection('banners').doc(editingId)
          : FirebaseFirestore.instance.collection('banners').doc();

      // ئەگەر وێنەیەکی نوێ هەڵبژێردرا، بار دەکرێت؛ ئەگەر نا،
      // لە دۆخی دەستکاریدا وێنەی کۆن دەمێنێتەوە وەک خۆی.
      String? imageUrl = existingImageUrl;
      if (imageFile != null) {
        imageUrl = await uploadToSupabase(
          bucket: 'banners',
          path: '${docRef.id}.jpg',
          file: imageFile!,
        );
      }

      if (isEditing) {
        // تەنها فیلدەکانی دەستکاریکراو نوێ دەکەینەوە، بۆ ئەوەی
        // 'order' و 'createdAt' ی ڕیکلامەکە نەگۆڕدرێت.
        await docRef.update({
          'title': title,
          'subtitle': subtitle,
          if (imageUrl != null) 'imageUrl': imageUrl,
        });
      } else {
        final banner = AppBanner(
          id: docRef.id,
          title: title,
          subtitle: subtitle,
          imageUrl: imageUrl,
          order: DateTime.now().millisecondsSinceEpoch,
        );
        await docRef.set(banner.toMap());
      }

      if (!mounted) return;
      titleController.clear();
      subtitleController.clear();
      setState(() {
        imageFile = null;
        isSubmitting = false;
        editingId = null;
        existingImageUrl = null;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isEditing ? 'ڕیکلامەکە نوێکرایەوە ✅' : 'ڕیکلامەکە زیادکرا ✅',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('هەڵە: $e')),
      );
    }
  }

  Future<void> _confirmDelete(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('سڕینەوەی ڕیکلام'),
        content: const Text('دڵنیایت لە سڕینەوەی ئەم ڕیکلامە؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('پاشگەزبوونەوە'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'سڕینەوە',
              style: TextStyle(color: errorColor),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await deleteBanner(id);
    }
  }

  // ⚠️ ئەم کلاسە پێشتر خۆی `_inputDecoration` ی نەبوو، بۆیە
  // بانگکردنەکانی خوارەوە بەهەڵە دەچوونە سەر فەنکشنی سەرەکی
  // (global) کە پێویستی بە hint/icon هەیە. ئێستا وەک ئەو
  // کلاسانەی تر (AdminAddProductScreen، هتد) خۆی نرخێکی
  // تایبەتی هەیە.
  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: cardSurfaceColor,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(title: const Text('ڕیکلامەکان')),
      body: Column(
        children: [
          Container(
            margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            padding: const EdgeInsets.all(16),
            decoration: softCardDecoration(),
            child: Row(
              children: [
                const Icon(Icons.timer_outlined, color: primaryBlue),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'کاتی گۆڕینی خۆکارانەی بانەر: $bannerIntervalSeconds چرکە',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  onPressed: bannerIntervalSeconds <= 2
                      ? null
                      : () {
                          final value = bannerIntervalSeconds - 1;
                          setState(() => bannerIntervalSeconds = value);
                          setBannerIntervalSeconds(value);
                        },
                  icon: const Icon(Icons.remove_circle_outline),
                ),
                IconButton(
                  onPressed: bannerIntervalSeconds >= 15
                      ? null
                      : () {
                          final value = bannerIntervalSeconds + 1;
                          setState(() => bannerIntervalSeconds = value);
                          setBannerIntervalSeconds(value);
                        },
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ],
            ),
          ),
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(16),
            decoration: softCardDecoration(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      editingId == null
                          ? 'زیادکردنی ڕیکلامی نوێ'
                          : 'دەستکاریکردنی ڕیکلام',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    if (editingId != null)
                      TextButton(
                        onPressed: _cancelEdit,
                        child: const Text('پاشگەزبوونەوە'),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'ئەگەر ناونیشان بەتاڵ بهێڵیتەوە، تەنها وێنەکە بە پاکی '
                  'دەردەکەوێت بەبێ هیچ نووسینێکی لەسەری (باشترە بۆ '
                  'وێنەی ئامادەکراوی جوان).',
                  style: TextStyle(color: secondaryText, fontSize: 12),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: titleController,
                  decoration: _inputDecoration('ناونیشان (ئارەزوومەندانە)'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: subtitleController,
                  decoration: _inputDecoration('ژێرنووس (ئارەزوومەندانە)'),
                ),
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: _pickImage,
                  child: Container(
                    height: 100,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(14),
                      image: imageFile != null
                          ? DecorationImage(
                              image: FileImage(imageFile!),
                              fit: BoxFit.cover,
                            )
                          : (existingImageUrl != null
                              ? DecorationImage(
                                  image: NetworkImage(existingImageUrl!),
                                  fit: BoxFit.cover,
                                )
                              : null),
                    ),
                    child: (imageFile == null && existingImageUrl == null)
                        ? Center(
                            child: Icon(
                              Icons.add_photo_alternate_outlined,
                              color: secondaryText,
                              size: 30,
                            ),
                          )
                        : null,
                  ),
                ),
                const SizedBox(height: 14),
                GradientButton(
                  label: editingId == null
                      ? 'زیادکردنی ڕیکلام'
                      : 'پاشەکەوتکردنی گۆڕانکارییەکان',
                  isLoading: isSubmitting,
                  onPressed: isSubmitting ? null : _saveBanner,
                  height: 48,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: AppRefresh(
              queries: [_bannersRef()],
              child: StreamBuilder<List<AppBanner>>(
              stream: bannersStream(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                final banners = snapshot.data ?? [];

                if (banners.isEmpty) {
                  return const EmptyState(
                    icon: Icons.campaign_outlined,
                    message: 'هیچ ڕیکلامێک نییە.',
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: banners.length,
                  itemBuilder: (context, index) {
                    final banner = banners[index];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(10),
                      decoration: softCardDecoration(),
                      child: Row(
                        children: [
                          Container(
                            width: 56,
                            height: 56,
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(
                              gradient: brandGradient,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: banner.imageUrl != null
                                ? Image.network(
                                    banner.imageUrl!,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        const Icon(
                                      Icons.image_outlined,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(
                                    Icons.campaign,
                                    color: Colors.white,
                                  ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  banner.title,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                if (banner.subtitle.isNotEmpty)
                                  Text(
                                    banner.subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: secondaryText,
                                      fontSize: 12,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: banner.isVisible
                                ? 'چالاکە (کرتە بکە بۆ ناچالاککردن)'
                                : 'ناچالاکە (کرتە بکە بۆ چالاککردن)',
                            onPressed: () async {
                              try {
                                await toggleBannerVisibility(
                                  banner.id,
                                  !banner.isVisible,
                                );
                              } catch (e) {
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('هەڵە: $e')),
                                );
                              }
                            },
                            icon: Icon(
                              banner.isVisible
                                  ? Icons.toggle_on
                                  : Icons.toggle_off_outlined,
                              color: banner.isVisible
                                  ? primaryBlue
                                  : secondaryText,
                              size: 32,
                            ),
                          ),
                          IconButton(
                            onPressed: () => _startEdit(banner),
                            icon: const Icon(
                              Icons.edit_outlined,
                              color: primaryBlue,
                            ),
                          ),
                          IconButton(
                            onPressed: () => _confirmDelete(banner.id),
                            icon: const Icon(
                              Icons.delete_outline,
                              color: errorColor,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            )),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// ADMIN COUPONS
// ============================================================

// ============================================================
// ADMIN — CATEGORIES
// ============================================================

class AdminCategoriesScreen extends StatefulWidget {
  const AdminCategoriesScreen({super.key});

  @override
  State<AdminCategoriesScreen> createState() =>
      _AdminCategoriesScreenState();
}

class _AdminCategoriesScreenState extends State<AdminCategoriesScreen> {
  final titleController = TextEditingController();
  String selectedIconKey = categoryIconOptions.keys.first;
  String selectedColorKey = categoryColorOptions.keys.first;
  bool isSubmitting = false;

  @override
  void dispose() {
    titleController.dispose();
    super.dispose();
  }

  Future<void> _addCategory() async {
    final title = titleController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تکایە ناوی پۆل بنووسە.')),
      );
      return;
    }

    setState(() => isSubmitting = true);

    try {
      final category = Category(
        id: '',
        title: title,
        icon: categoryIconOptions[selectedIconKey]!,
        color: categoryColorOptions[selectedColorKey]!,
      );
      await _categoriesRef().add(category.toMap());

      if (!mounted) return;
      titleController.clear();
      setState(() => isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('پۆلەکە زیادکرا ✅')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('هەڵە: $e')),
      );
    }
  }

  Future<void> _confirmDelete(String id, String title) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('سڕینەوەی پۆل'),
        content: Text('دڵنیایت لە سڕینەوەی "$title"؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('پاشگەزبوونەوە'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'سڕینەوە',
              style: TextStyle(color: errorColor),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _categoriesRef().doc(id).delete();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(title: const Text('پۆلەکان')),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: cardSurfaceColor,
              border: Border(
                bottom: BorderSide(color: cardBorderColor),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'زیادکردنی پۆلی نوێ',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: titleController,
                  decoration: _inputDecoration(
                    hint: 'ناوی پۆل *',
                    icon: Icons.category_outlined,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: selectedIconKey,
                        isExpanded: true,
                        decoration: _inputDecoration(
                          hint: 'ئایکۆن',
                          icon: Icons.emoji_symbols_outlined,
                        ),
                        items: categoryIconOptions.keys
                            .map(
                              (key) => DropdownMenuItem(
                                value: key,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      categoryIconOptions[key],
                                      size: 18,
                                    ),
                                    const SizedBox(width: 6),
                                    Flexible(
                                      child: Text(
                                        key,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() => selectedIconKey = value);
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: selectedColorKey,
                        isExpanded: true,
                        decoration: _inputDecoration(
                          hint: 'ڕەنگ',
                          icon: Icons.palette_outlined,
                        ),
                        items: categoryColorOptions.keys
                            .map(
                              (key) => DropdownMenuItem(
                                value: key,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 14,
                                      height: 14,
                                      decoration: BoxDecoration(
                                        color: categoryColorOptions[key],
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Flexible(
                                      child: Text(
                                        key,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() => selectedColorKey = value);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                GradientButton(
                  label: 'زیادکردنی پۆل',
                  isLoading: isSubmitting,
                  onPressed: isSubmitting ? null : _addCategory,
                  height: 48,
                ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<List<Category>>(
              stream: categoriesStream(),
              builder: (context, snapshot) {
                final categories = snapshot.data ?? [];

                if (categories.isEmpty) {
                  return const EmptyState(
                    icon: Icons.category_outlined,
                    message: 'هێشتا هیچ پۆلێک نییە.',
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(18),
                  itemCount: categories.length,
                  itemBuilder: (context, index) {
                    final category = categories[index];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      decoration: softCardDecoration(),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: category.color.withValues(alpha: 0.12),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(category.icon, color: category.color),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              category.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: errorColor,
                            ),
                            onPressed: () => _confirmDelete(
                              category.id,
                              category.title,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class AdminCouponsScreen extends StatefulWidget {
  const AdminCouponsScreen({super.key});

  @override
  State<AdminCouponsScreen> createState() => _AdminCouponsScreenState();
}

class _AdminCouponsScreenState extends State<AdminCouponsScreen> {
  final codeController = TextEditingController();
  final discountController = TextEditingController();
  bool isSubmitting = false;

  @override
  void dispose() {
    codeController.dispose();
    discountController.dispose();
    super.dispose();
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: cardSurfaceColor,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    );
  }

  Future<void> _addCoupon() async {
    final code = codeController.text.trim();
    final discount = int.tryParse(discountController.text.trim());

    if (code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تکایە کۆدی کۆپۆن بنووسە.')),
      );
      return;
    }

    if (discount == null || discount <= 0 || discount > 100) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تکایە ڕێژەی داشکاندن (١-١٠٠) بنووسە.'),
        ),
      );
      return;
    }

    setState(() => isSubmitting = true);

    try {
      await addCoupon(code: code, discountPercent: discount);

      if (!mounted) return;
      codeController.clear();
      discountController.clear();
      setState(() => isSubmitting = false);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('کۆپۆنەکە زیادکرا ✅')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('هەڵە: $e')),
      );
    }
  }

  Future<void> _confirmDelete(String code) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('سڕینەوەی کۆپۆن'),
        content: Text('دڵنیایت لە سڕینەوەی کۆدی "$code"؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('پاشگەزبوونەوە'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'سڕینەوە',
              style: TextStyle(color: errorColor),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await deleteCoupon(code);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(title: const Text('کۆپۆنەکان')),
      body: Column(
        children: [
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(16),
            decoration: softCardDecoration(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'زیادکردنی کۆپۆنی نوێ',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: codeController,
                  textCapitalization: TextCapitalization.characters,
                  decoration: _inputDecoration('کۆدی کۆپۆن (وەک: ZNAR20)'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: discountController,
                  keyboardType: TextInputType.number,
                  decoration: _inputDecoration('ڕێژەی داشکاندن (%)'),
                ),
                const SizedBox(height: 14),
                GradientButton(
                  label: 'زیادکردنی کۆپۆن',
                  isLoading: isSubmitting,
                  onPressed: isSubmitting ? null : _addCoupon,
                  height: 48,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: AppRefresh(
              queries: [_couponsRef()],
              child: StreamBuilder<List<Coupon>>(
              stream: couponsStream(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                final coupons = snapshot.data ?? [];

                if (coupons.isEmpty) {
                  return const EmptyState(
                    icon: Icons.local_offer_outlined,
                    message: 'هیچ کۆپۆنێک نییە.',
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: coupons.length,
                  itemBuilder: (context, index) {
                    final coupon = coupons[index];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(14),
                      decoration: softCardDecoration(),
                      child: Row(
                        children: [
                          Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              color: Colors.deepPurple.withValues(alpha: .10),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.local_offer,
                              color: Colors.deepPurple,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  coupon.code,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${coupon.discountPercent}% داشکاندن'
                                  '${coupon.active ? '' : ' — ناچالاک'}',
                                  style: TextStyle(
                                    color: coupon.active
                                        ? successColor
                                        : secondaryText,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: coupon.active,
                            activeColor: primaryBlue,
                            onChanged: (value) {
                              setCouponActive(coupon.code, value);
                            },
                          ),
                          IconButton(
                            onPressed: () => _confirmDelete(coupon.code),
                            icon: const Icon(
                              Icons.delete_outline,
                              color: errorColor,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            )),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// ADMIN — SEND NOTIFICATION
// ============================================================

class AdminSendNotificationScreen extends StatefulWidget {
  const AdminSendNotificationScreen({super.key});

  @override
  State<AdminSendNotificationScreen> createState() =>
      _AdminSendNotificationScreenState();
}

class _AdminSendNotificationScreenState
    extends State<AdminSendNotificationScreen> {
  final titleController = TextEditingController();
  final bodyController = TextEditingController();
  bool isSending = false;

  @override
  void dispose() {
    titleController.dispose();
    bodyController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final title = titleController.text.trim();
    final body = bodyController.text.trim();

    if (title.isEmpty || body.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تکایە ناونیشان و ناوەڕۆک بنووسە.')),
      );
      return;
    }

    setState(() => isSending = true);

    try {
      // ئەم بەڵگەنامەیە تەنها لە Firestore خەزن دەکرێت. کۆدی
      // Flutter ناتوانێت ڕاستەوخۆ FCM بنێرێت (پێویستی بە کلیلی
      // نهێنی سێرڤەرە) — بۆیە Cloud Function ـێک (بڕوانە
      // send_notifications_function.js) گوێدەگرێت بۆ زیادبوونی
      // بەڵگەنامەیەکی نوێ لێرە، و ئینجا ڕاستەقینە بۆ هەموو
      // بەکارهێنەران دەینێرێت لە ڕێگەی topic ی 'all_users'.
      await FirebaseFirestore.instance.collection('broadcasts').add({
        'title': title,
        'body': body,
        'sentBy': FirebaseAuth.instance.currentUser?.uid,
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      titleController.clear();
      bodyController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ڕاگەیاندنەکە نێردرا ✅')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('هەڵە: $e')),
      );
    } finally {
      if (mounted) setState(() => isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(title: const Text('ناردنی ڕاگەیاندن')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: primaryBlue.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline, color: primaryBlue),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'ئەم ڕاگەیاندنە دەگاتە هەموو بەکارهێنەرانی ئەپەکە '
                    '— وەک بەرهەمی نوێ، وەشانی نوێ، یان هەر '
                    'هەواڵێکی تر.',
                    style: TextStyle(color: primaryBlue, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: titleController,
            decoration: _inputDecoration(
              hint: 'ناونیشانی ڕاگەیاندن *',
              icon: Icons.title,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: bodyController,
            maxLines: 4,
            decoration: _inputDecoration(
              hint: 'ناوەڕۆکی ڕاگەیاندن *',
              icon: Icons.notes,
            ),
          ),
          const SizedBox(height: 22),
          GradientButton(
            label: isSending ? 'ناردن...' : 'ناردنی ڕاگەیاندن',
            isLoading: isSending,
            onPressed: isSending ? null : _send,
          ),
        ],
      ),
    );
  }
}

// ============================================================
// NOTIFICATIONS SCREEN (inbox ـی ڕاگەیاندنەکان)
// ============================================================

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  // ناسنامەی ئەو ڕاگەیاندنانەی بەکارهێنەر لابردوونی — تەنها لەسەر
  // ئەم ئامێرە خەزن دەکرێت (SharedPreferences)، کاریگەری لەسەر
  // بەکارهێنەرانی تر نابێت، چونکە کۆلیکشنی 'broadcasts' هاوبەشە.
  Set<String> dismissedIds = {};
  bool isLoaded = false;

  @override
  void initState() {
    super.initState();
    // کاتێک بەکارهێنەر ئەم پەڕەیە دەکاتەوە، هەمووی وەک
    // خوێندراوە نیشانە دەکرێت (بۆ لابردنی خاڵی سووری بادج).
    markNotificationsSeenNow();
    _loadDismissed();
  }

  Future<void> _loadDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('dismissed_notification_ids') ?? [];
    if (!mounted) return;
    setState(() {
      dismissedIds = list.toSet();
      isLoaded = true;
    });
  }

  Future<void> _saveDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'dismissed_notification_ids',
      dismissedIds.toList(),
    );
  }

  void _dismissOne(String id) {
    setState(() => dismissedIds.add(id));
    _saveDismissed();
  }

  Future<void> _clearAll(List<String> visibleIds) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('سڕینەوەی هەموو ڕاگەیاندنەکان'),
        content: const Text(
          'دڵنیایت لە سڕینەوەی هەموو ڕاگەیاندنەکان لەلای خۆت؟',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('پاشگەزبوونەوە'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'سڕینەوە',
              style: TextStyle(color: errorColor),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => dismissedIds.addAll(visibleIds));
    await _saveDismissed();
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'ئێستا';
    if (diff.inMinutes < 60) return 'بەر لە ${diff.inMinutes} خولەک';
    if (diff.inHours < 24) return 'بەر لە ${diff.inHours} کاتژمێر';
    if (diff.inDays < 7) return 'بەر لە ${diff.inDays} ڕۆژ';
    return '${dt.year}/${dt.month}/${dt.day}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: const Text('ڕاگەیاندنەکان'),
        actions: [
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: broadcastsStream(),
            builder: (context, snapshot) {
              final visible = (snapshot.data ?? [])
                  .where((i) => !dismissedIds.contains(i['id']))
                  .toList();
              if (visible.isEmpty) return const SizedBox.shrink();

              return IconButton(
                tooltip: 'سڕینەوەی هەموو',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: () => _clearAll(
                  visible.map((i) => i['id'] as String).toList(),
                ),
              );
            },
          ),
        ],
      ),
      body: !isLoaded
          ? const Center(child: CircularProgressIndicator())
          : AppRefresh(
              queries: [FirebaseFirestore.instance.collection('broadcasts')],
              child: StreamBuilder<List<Map<String, dynamic>>>(
        stream: broadcastsStream(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'هەڵەیەک ڕوویدا: ${snapshot.error}',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: secondaryText),
                ),
              ),
            );
          }

          final items = (snapshot.data ?? [])
              .where((i) => !dismissedIds.contains(i['id']))
              .toList();

          if (items.isEmpty) {
            return const EmptyState(
              icon: Icons.notifications_none_rounded,
              message: 'هێشتا هیچ ڕاگەیاندنێک نییە.',
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(18),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final id = item['id'] as String;
              final title = item['title'] as String? ?? '';
              final body = item['body'] as String? ?? '';
              final createdAt = item['createdAt'];
              final dt = createdAt is Timestamp ? createdAt.toDate() : null;

              return Dismissible(
                key: ValueKey(id),
                direction: DismissDirection.endToStart,
                onDismissed: (_) => _dismissOne(id),
                background: Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  alignment: Alignment.centerRight,
                  decoration: BoxDecoration(
                    color: errorColor,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(
                    Icons.delete_outline,
                    color: Colors.white,
                  ),
                ),
                child: Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(14),
                decoration: softCardDecoration(),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: primaryBlue.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.campaign_rounded,
                        color: primaryBlue,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14.5,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            body,
                            style: TextStyle(
                              color: secondaryText,
                              fontSize: 13,
                              height: 1.4,
                            ),
                          ),
                          if (dt != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              _timeAgo(dt),
                              style: TextStyle(
                                color: secondaryText,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              );
            },
          );
        },
      )),
    );
  }
}

class PurchaseSheet extends StatefulWidget {
  final Product product;

  const PurchaseSheet({
    super.key,
    required this.product,
  });

  @override
  State<PurchaseSheet> createState() =>
      _PurchaseSheetState();
}

class _PurchaseSheetState
    extends State<PurchaseSheet> {
  final couponController = TextEditingController();

  bool couponApplied = false;
  bool isCheckingCoupon = false;
  int couponDiscountPercent = 0;

  double get finalPrice {
    if (couponApplied) {
      return widget.product.price * (1 - couponDiscountPercent / 100);
    }

    return widget.product.price;
  }

  Future<void> applyCoupon() async {
    final code = couponController.text.trim().toUpperCase();
    if (code.isEmpty) return;

    setState(() => isCheckingCoupon = true);
    final discount = await validateCoupon(code);
    if (!mounted) return;
    setState(() => isCheckingCoupon = false);

    if (discount != null) {
      setState(() {
        couponApplied = true;
        couponDiscountPercent = discount;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'کۆپۆنی $code بە سەرکەوتوویی جێبەجێ کرا. $discount% داشکاندن 🎉',
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'کۆدی کۆپۆن دروست نییە.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        20,
        15,
        20,
        25,
      ),
      decoration: BoxDecoration(
        color: cardSurfaceColor,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(28),
        ),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 45,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),

            const SizedBox(height: 22),

            const Text(
              'پشتڕاستکردنەوەی کڕین',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 18),

            Row(
              children: [
                Container(
                  width: 60,
                  height: 60,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: ProductThumbnail(
                    product: widget.product,
                    width: 60,
                    height: 60,
                    borderRadius: 15,
                  ),
                ),

                const SizedBox(width: 12),

                Expanded(
                  child: Text(
                    widget.product.title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),

            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: couponController,
                    textCapitalization:
                        TextCapitalization.characters,
                    decoration: InputDecoration(
                      hintText: 'کۆدی کۆپۆن',
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),

                const SizedBox(width: 8),

                SizedBox(
                  height: 55,
                  child: ElevatedButton(
                    onPressed: isCheckingCoupon ? null : applyCoupon,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: primaryBlue,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: isCheckingCoupon
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            'جێبەجێکردن',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 22),

            if (couponApplied)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: successColor.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  children: [
                    Icon(
                      Icons.check_circle,
                      color: successColor,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '20% داشکاندن هاتە جێبەجێکرن .',
                        style: TextStyle(
                          color: successColor,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 20),

            Row(
              mainAxisAlignment:
                  MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'کۆی گشتی:',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  formatIQD(finalPrice),
                  style: const TextStyle(
                    fontSize: 25,
                    color: primaryBlue,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(context); // داخستنی PurchaseSheet

                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ManualPaymentScreen(
                        items: [widget.product],
                        amountIQD: finalPrice,
                        couponCode: couponApplied
                            ? couponController.text.trim().toUpperCase()
                            : null,
                      ),
                    ),
                  );
                },
                icon: const Icon(
                  Icons.payment_rounded,
                ),
                label: const Text(
                  'بەردەوامبوون بۆ پارەدان',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryBlue,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// CART SCREEN
// ============================================================

class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  final couponController = TextEditingController();
  bool couponApplied = false;
  bool isCheckingOut = false;
  bool isCheckingCoupon = false;
  int couponDiscountPercent = 0;

  Future<void> applyCoupon() async {
    final code = couponController.text.trim().toUpperCase();
    if (code.isEmpty) return;

    setState(() => isCheckingCoupon = true);
    final discount = await validateCoupon(code);
    if (!mounted) return;
    setState(() => isCheckingCoupon = false);

    if (discount != null) {
      setState(() {
        couponApplied = true;
        couponDiscountPercent = discount;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'کۆپۆنی $code بە سەرکەوتوویی جێبەجێ کرا. $discount% داشکاندن 🎉',
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('کۆدی کۆپۆن دروست نییە.')),
      );
    }
  }

  double _total(List<Product> items) {
    final sum = items.fold<double>(0, (t, p) => t + p.price);
    return couponApplied ? sum * (1 - couponDiscountPercent / 100) : sum;
  }

  void _checkout(List<Product> items) {
    if (items.isEmpty || isCheckingOut) return;

    setState(() => isCheckingOut = true);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ManualPaymentScreen(
          items: items,
          amountIQD: _total(items),
          couponCode: couponApplied
              ? couponController.text.trim().toUpperCase()
              : null,
        ),
      ),
    ).then((_) {
      if (mounted) setState(() => isCheckingOut = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(title: const Text('سەبەتەی کڕین')),
      body: AppRefresh(
        queries: [_cartRef(), _productsRef()],
        child: StreamBuilder<Set<String>>(
        stream: cartIdsStream(),
        builder: (context, cartSnap) {
          final cartIds = cartSnap.data ?? <String>{};

          if (cartSnap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (cartIds.isEmpty) {
            return const EmptyState(
              icon: Icons.shopping_cart_outlined,
              message: 'سەبەتەی کڕینت بەتاڵە.',
            );
          }

          return StreamBuilder<List<Product>>(
            stream: productsStream(),
            builder: (context, prodSnap) {
              if (prodSnap.connectionState == ConnectionState.waiting &&
                  !prodSnap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final all = prodSnap.data ?? sampleProducts;
              final items =
                  all.where((p) => cartIds.contains(p.id)).toList();

              // پێشتر لێرە spinner ـی بێ کۆتایی پیشان دەدرا ئەگەر
              // بەرهەمێکی سەبەتە سڕابووەوە.
              if (items.isEmpty) {
                return const EmptyState(
                  icon: Icons.shopping_cart_outlined,
                  message: 'سەبەتەی کڕینت بەتاڵە.',
                );
              }

              return Column(
                children: [
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.all(18),
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        return _CartTile(product: items[index]);
                      },
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 25),
                    decoration: BoxDecoration(
                      color: cardSurfaceColor,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.06),
                          blurRadius: 20,
                          offset: const Offset(0, -4),
                        ),
                      ],
                    ),
                    child: SafeArea(
                      top: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: couponController,
                                  textCapitalization:
                                      TextCapitalization.characters,
                                  decoration: InputDecoration(
                                    hintText: 'کۆدی کۆپۆن',
                                    border: OutlineInputBorder(
                                      borderRadius:
                                          BorderRadius.circular(14),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                height: 55,
                                child: ElevatedButton(
                                  onPressed:
                                      isCheckingCoupon ? null : applyCoupon,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: primaryBlue,
                                    foregroundColor: Colors.white,
                                    elevation: 0,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 18,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(14),
                                    ),
                                  ),
                                  child: isCheckingCoupon
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : const Text(
                                          'جێبەجێکردن',
                                          style: TextStyle(
                                              fontWeight: FontWeight.w600),
                                        ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'کۆی گشتی:',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                formatIQD(_total(items)),
                                style: const TextStyle(
                                  fontSize: 25,
                                  color: primaryBlue,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            height: 56,
                            child: ElevatedButton.icon(
                              onPressed: isCheckingOut
                                  ? null
                                  : () => _checkout(items),
                              icon: isCheckingOut
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.payment_rounded),
                              label: const Text(
                                'بەردەوامبوون بۆ پارەدان',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: primaryBlue,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      )),
    );
  }
}

class _CartTile extends StatelessWidget {
  final Product product;

  const _CartTile({required this.product});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: softCardDecoration(),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(kRadiusMd),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ProductDetailsScreen(product: product),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ProductThumbnail(
                  product: product,
                  width: 64,
                  height: 64,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        product.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        product.category,
                        style: TextStyle(
                          color: secondaryText,
                          fontSize: 12.5,
                        ),
                      ),
                      const SizedBox(height: 6),
                      if (!product.isFree)
                        Text(
                          formatIQD(product.price),
                          style: const TextStyle(
                            color: primaryBlue,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => removeFromCart(product.id),
                  icon: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// SEARCH
// ============================================================

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController searchController =
      TextEditingController();
  String query = '';

  // فلتەرەکان — بەتاڵ واتە هیچ سنوورێک نییە بۆ ئەو خانەیە.
  String? filterCategory;
  String? filterLanguage;
  double filterMinRating = 0;

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  bool get _hasActiveFilters =>
      filterCategory != null || filterLanguage != null || filterMinRating > 0;

  void _clearFilters() {
    setState(() {
      filterCategory = null;
      filterLanguage = null;
      filterMinRating = 0;
    });
  }

  /// پشکنین دەکات ئایا بەرهەمەکە لەگەڵ دەقی گەڕانەکە و
  /// فلتەرەکان دەگونجێت (ناو، پۆل، نووسەر — بەبێ گرنگیدان بە
  /// گەورە/بچووکی پیت — زیادکراوە کاتیگۆری، زمان و کەمترین نرخ).
  bool _matches(Product product, String q) {
    if (filterCategory != null && product.category != filterCategory) {
      return false;
    }
    if (filterLanguage != null && product.language != filterLanguage) {
      return false;
    }
    if (filterMinRating > 0 && product.rating < filterMinRating) {
      return false;
    }

    if (q.isEmpty) return true;
    final lowerQ = q.toLowerCase();
    return product.title.toLowerCase().contains(lowerQ) ||
        product.category.toLowerCase().contains(lowerQ) ||
        product.author.toLowerCase().contains(lowerQ);
  }

  void _openFilterSheet(List<Category> categories) {
    String? tempCategory = filterCategory;
    String? tempLanguage = filterLanguage;
    double tempRating = filterMinRating;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            return Container(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 20,
              ),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'فلتەرکردنی گەڕان',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: darkText,
                    ),
                  ),
                  const SizedBox(height: 18),

                  Text(
                    'پۆل',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: secondaryText,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('هەموو'),
                        selected: tempCategory == null,
                        onSelected: (_) =>
                            setSheetState(() => tempCategory = null),
                      ),
                      ...categories.map(
                        (c) => ChoiceChip(
                          label: Text(c.title),
                          selected: tempCategory == c.title,
                          onSelected: (_) => setSheetState(
                            () => tempCategory = c.title,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 18),
                  Text(
                    'زمانی ناوەڕۆک',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: secondaryText,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('هەموو'),
                        selected: tempLanguage == null,
                        onSelected: (_) =>
                            setSheetState(() => tempLanguage = null),
                      ),
                      ...productLanguages.map(
                        (lang) => ChoiceChip(
                          label: Text(lang),
                          selected: tempLanguage == lang,
                          onSelected: (_) => setSheetState(
                            () => tempLanguage = lang,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 18),
                  Text(
                    'کەمترین هەڵسەنگاندن',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: secondaryText,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [0.0, 3.0, 4.0, 4.5].map((r) {
                      final label = r == 0.0 ? 'هەموو' : '$r ⭐+';
                      return ChoiceChip(
                        label: Text(label),
                        selected: tempRating == r,
                        onSelected: (_) => setSheetState(
                          () => tempRating = r,
                        ),
                      );
                    }).toList(),
                  ),

                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            setSheetState(() {
                              tempCategory = null;
                              tempLanguage = null;
                              tempRating = 0;
                            });
                          },
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              vertical: 14,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: const Text('سڕینەوەی فلتەر'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () {
                            setState(() {
                              filterCategory = tempCategory;
                              filterLanguage = tempLanguage;
                              filterMinRating = tempRating;
                            });
                            Navigator.pop(sheetContext);
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: primaryBlue,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              vertical: 14,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: const Text('جێبەجێکردن'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: const Text('گەڕان'),
      ),
      body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 5),

            StreamBuilder<List<Category>>(
              stream: categoriesStream(),
              builder: (context, categorySnapshot) {
                final categories =
                    categorySnapshot.data ?? sampleCategories;

                return Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: searchController,
                        onChanged: (value) {
                          setState(() => query = value);
                        },
                        decoration: InputDecoration(
                          hintText: 'بەرهەم بگەڕێ...',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: query.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close),
                                  onPressed: () {
                                    searchController.clear();
                                    setState(() => query = '');
                                  },
                                ),
                          filled: true,
                          fillColor: cardSurfaceColor,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(17),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            color: _hasActiveFilters
                                ? primaryBlue
                                : cardSurfaceColor,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: IconButton(
                            onPressed: () => _openFilterSheet(categories),
                            icon: Icon(
                              Icons.tune_rounded,
                              color: _hasActiveFilters
                                  ? Colors.white
                                  : darkText,
                            ),
                          ),
                        ),
                        if (_hasActiveFilters)
                          Positioned(
                            top: -2,
                            left: -2,
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: const BoxDecoration(
                                color: errorColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),

            if (_hasActiveFilters) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (filterCategory != null)
                    Chip(
                      label: Text(filterCategory!),
                      onDeleted: () =>
                          setState(() => filterCategory = null),
                    ),
                  if (filterLanguage != null)
                    Chip(
                      label: Text(filterLanguage!),
                      onDeleted: () =>
                          setState(() => filterLanguage = null),
                    ),
                  if (filterMinRating > 0)
                    Chip(
                      label: Text('$filterMinRating ⭐+'),
                      onDeleted: () =>
                          setState(() => filterMinRating = 0),
                    ),
                  ActionChip(
                    label: const Text('سڕینەوەی هەموو'),
                    onPressed: _clearFilters,
                  ),
                ],
              ),
            ],

            const SizedBox(height: 25),

            const Text(
              'بەرهەمەکان',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 15),

            Expanded(
              child: AppRefresh(
                queries: [_productsRef()],
                child: StreamBuilder<List<Product>>(
                stream: productsStream(activeOnly: true),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting &&
                      !snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final allProducts = snapshot.data ?? sampleProducts;

                  final products = allProducts
                      .where((p) => _matches(p, query))
                      .toList();

                  if (products.isEmpty) {
                    return const EmptyState(
                      icon: Icons.search_off,
                      message: 'هیچ بەرهەمێک نەدۆزرایەوە.',
                    );
                  }

                  return ListView.builder(
                    itemCount: products.length,
                    itemBuilder: (context, index) {
                      return _FavoriteTile(
                        product: products[index],
                      );
                    },
                  );
                },
              )),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

// ============================================================
// LIBRARY
// ============================================================

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            child: Text(
              'پەرتوکخانە',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: darkText,
              ),
            ),
          ),
          Expanded(
            child: AppRefresh(
              queries: [_libraryRef(), _productsRef()],
              child: StreamBuilder<Set<String>>(
              stream: libraryIdsStream(),
              builder: (context, snapshot) {
                if (snapshot.connectionState ==
                    ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(),
                  );
                }

                final libraryIds = snapshot.data ?? <String>{};

                return StreamBuilder<List<Product>>(
                  stream: productsStream(),
                  builder: (context, productsSnapshot) {
                    if (productsSnapshot.connectionState ==
                            ConnectionState.waiting &&
                        !productsSnapshot.hasData) {
                      return const Center(
                        child: CircularProgressIndicator(),
                      );
                    }

                    final allProducts =
                        productsSnapshot.data ?? sampleProducts;

                    final libraryProducts = allProducts
                        .where((p) => libraryIds.contains(p.id))
                        .toList();

                    if (libraryProducts.isEmpty) {
                      return const EmptyState(
                        icon: Icons.library_books_outlined,
                        message:
                            'دوای کڕینی بەرهەمەکان لێرە پیشان دەدرێن.',
                      );
                    }

                    return ListView.builder(
                      padding:
                          const EdgeInsets.fromLTRB(18, 4, 18, 132),
                      itemCount: libraryProducts.length,
                      itemBuilder: (context, index) {
                        return _LibraryTile(
                          product: libraryProducts[index],
                        );
                      },
                    );
                  },
                );
              },
            )),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------
// LIBRARY TILE
// ------------------------------------------------------------

class _LibraryTile extends StatelessWidget {
  final Product product;

  const _LibraryTile({required this.product});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: softCardDecoration(),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(kRadiusMd),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    ProductDetailsScreen(product: product),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ProductThumbnail(
                  product: product,
                  width: 64,
                  height: 64,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        product.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        product.category,
                        style: TextStyle(
                          color: secondaryText,
                          fontSize: 12.5,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(
                            Icons.check_circle,
                            size: 14,
                            color: successColor,
                          ),
                          const SizedBox(width: 4),
                          const Text(
                            'کڕدراوە',
                            style: TextStyle(
                              color: successColor,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_left,
                  color: secondaryText,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// FAVORITES
// ============================================================

class FavoritesScreen extends StatelessWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            child: Text(
              'دڵخوازەکان',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: darkText,
              ),
            ),
          ),
          Expanded(
            child: AppRefresh(
              queries: [_favoritesRef(), _productsRef()],
              child: StreamBuilder<Set<String>>(
              stream: favoriteIdsStream(),
              builder: (context, snapshot) {
                if (snapshot.connectionState ==
                    ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(),
                  );
                }

                final favoriteIds = snapshot.data ?? <String>{};

                return StreamBuilder<List<Product>>(
                  stream: productsStream(),
                  builder: (context, productsSnapshot) {
                    if (productsSnapshot.connectionState ==
                            ConnectionState.waiting &&
                        !productsSnapshot.hasData) {
                      return const Center(
                        child: CircularProgressIndicator(),
                      );
                    }

                    final allProducts =
                        productsSnapshot.data ?? sampleProducts;

                    final favoriteProducts = allProducts
                        .where((p) => favoriteIds.contains(p.id))
                        .toList();

                    if (favoriteProducts.isEmpty) {
                      return const EmptyState(
                        icon: Icons.favorite_border,
                        message: 'بەرهەمە دڵخوازەکانت لێرە دەبینیت.',
                      );
                    }

                    return ListView.builder(
                      padding:
                          const EdgeInsets.fromLTRB(18, 4, 18, 132),
                      itemCount: favoriteProducts.length,
                      itemBuilder: (context, index) {
                        return _FavoriteTile(
                          product: favoriteProducts[index],
                        );
                      },
                    );
                  },
                );
              },
            )),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------
// FAVORITE TILE
// ------------------------------------------------------------

class _FavoriteTile extends StatelessWidget {
  final Product product;

  const _FavoriteTile({required this.product});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: softCardDecoration(),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(kRadiusMd),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    ProductDetailsScreen(product: product),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ProductThumbnail(
                  product: product,
                  width: 64,
                  height: 64,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        product.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        product.category,
                        style: TextStyle(
                          color: secondaryText,
                          fontSize: 12.5,
                        ),
                      ),
                      const SizedBox(height: 6),
                      if (!product.isFree)
                        Text(
                          formatIQD(product.price),
                          style: const TextStyle(
                            color: primaryBlue,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => toggleFavorite(product.id),
                  icon: const Icon(
                    Icons.favorite,
                    color: Colors.red,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// PROFILE
// ============================================================

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  // وێنەی پرۆفایل تەنها لەسەر ئەم ئامێرە خەزن دەکرێت (وەک
  // وێنەی پرۆفایلی WhatsApp) — هیچ کاتێک نانێردرێت بۆ هیچ
  // سێرڤەر یان خزمەتگوزاریەکی دەرەکی.
  String? localPhotoPath;

  @override
  void initState() {
    super.initState();
    _loadLocalPhoto();
  }

  Future<void> _loadLocalPhoto() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString('profile_photo_path_$uid');

    if (!mounted) return;
    setState(() {
      localPhotoPath = path;
    });
  }

  // ==========================================================
  // CHANGE LANGUAGE
  // ==========================================================

  Future<void> _changeLanguage(
    BuildContext context,
    String languageCode,
  ) async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(
      'language',
      languageCode,
    );

    localeNotifier.value = Locale(languageCode);
  }

  // ==========================================================
  // LANGUAGE DIALOG
  // ==========================================================

  void _showLanguageDialog(BuildContext context) {
    final currentLanguage =
        localeNotifier.value.languageCode;

    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(
            context.tr('languageTitle'),
            style: const TextStyle(
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _languageOption(
                context: dialogContext,
                code: 'ku',
                title: context.tr('kurdish'),
                flag: '🇹🇯',
                currentLanguage: currentLanguage,
              ),

              _languageOption(
                context: dialogContext,
                code: 'ar',
                title: context.tr('arabic'),
                flag: '🇸🇦',
                currentLanguage: currentLanguage,
              ),

              _languageOption(
                context: dialogContext,
                code: 'en',
                title: context.tr('english'),
                flag: '🇬🇧',
                currentLanguage: currentLanguage,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
              },
              child: Text(
                context.tr('cancel'),
              ),
            ),
          ],
        );
      },
    );
  }

  // ==========================================================
  // LANGUAGE OPTION
  // ==========================================================

  Widget _languageOption({
    required BuildContext context,
    required String code,
    required String title,
    required String flag,
    required String currentLanguage,
  }) {
    final selected = currentLanguage == code;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 4,
        vertical: 2,
      ),
      leading: Text(
        flag,
        style: const TextStyle(
          fontSize: 25,
        ),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontWeight:
              selected ? FontWeight.bold : FontWeight.w500,
        ),
      ),
      trailing: selected
          ? const Icon(
              Icons.check_circle,
              color: primaryBlue,
            )
          : null,
      onTap: () async {
        Navigator.pop(context);

        await _changeLanguage(
          context,
          code,
        );
      },
    );
  }

  // ==========================================================
  // LOGOUT
  // ==========================================================

  Future<void> _logout(BuildContext context) async {
    try {
      await FirebaseAuth.instance.signOut();

      if (!context.mounted) return;

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => const LoginScreen(),
        ),
        (route) => false,
      );
    } on FirebaseAuthException {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'نەتوانرا لە ئەکاونتەکە بچیتە دەرەوە.',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } catch (e) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'هەڵەیەک ڕوویدا. تکایە دووبارە هەوڵ بدە.',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  // ==========================================================
  // LOGOUT CONFIRMATION
  // ==========================================================

  void _showLogoutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(
            context.tr('logout'),
            style: const TextStyle(
              fontWeight: FontWeight.bold,
            ),
          ),
          content: const Text(
            'دڵنیایت دەتەوێت لە ئەکاونتەکەت بچیتە دەرەوە؟',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
              },
              child: Text(
                context.tr('cancel'),
              ),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(dialogContext);

                await _logout(context);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                context.tr('logout'),
              ),
            ),
          ],
        );
      },
    );
  }

  // ==========================================================
  // PROFILE
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    // ئەگەر هیچ بەکارهێنەرێک چوونەژوورەوەی نەکردبێت
    // (وادەبێت ئەم دۆخە ڕووی نەدات چونکە تەنها ProfileScreen
    // دوای چوونەژوورەوە پیشان دەدرێت).
    if (user == null) {
      return const Center(
        child: Text('تکایە سەرەتا بچۆ ژوورەوە.'),
      );
    }

    return SafeArea(
      // --------------------------------------------------------
      // خوێندنەوەی زیندووی داتای بەکارهێنەر لە Cloud Firestore
      // (collection('users').doc(uid)) کە لە کاتی SignUp دا
      // خەزن کرا. ئەمە وادەکات هەر گۆڕانکارییەک لە داتاکە
      // (وەک لە Edit Profile) ڕاستەوخۆ لێرەش نوێ ببێتەوە.
      // --------------------------------------------------------
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          if (snapshot.hasError) {
            return Center(
              child: Text(
                'نەتوانرا زانیاری هەژمار بهێنرێت.\n(${snapshot.error})',
                textAlign: TextAlign.center,
                style: TextStyle(color: secondaryText),
              ),
            );
          }

          final firestoreData = snapshot.data?.data();

          // ناو: سەرەتا لە Firestore، ئەگەر نەبوو لە Firebase Auth
          final userName =
              (firestoreData?['name'] as String?)?.trim().isNotEmpty == true
                  ? firestoreData!['name'] as String
                  : (user.displayName?.trim().isNotEmpty == true
                      ? user.displayName!
                      : context.tr('student'));

          // ئیمەیڵ: سەرەتا لە Firestore، ئەگەر نەبوو لە Firebase Auth
          final userEmail =
              (firestoreData?['email'] as String?) ??
                  user.email ??
                  'student@znar.academy';

          // بەرواری تۆمارکردنی هەژمار (ئەگەر لە Firestore هەبوو)
          String? joinedText;
          final createdAtTs = firestoreData?['createdAt'];
          if (createdAtTs is Timestamp) {
            final date = createdAtTs.toDate();
            joinedText =
                'ئەندام بووە لە ${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
          }

          // وێنەی پرۆفایل: تەنها لەسەر ئەم ئامێرە خەزن دەکرێت
          // (وەک واتساپ)، هەرگیز بۆ هیچ سێرڤەرێک نانێردرێت.
          final hasLocalPhoto =
              localPhotoPath != null && File(localPhotoPath!).existsSync();

          return ListView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 132),
        children: [
          // ====================================================
          // TITLE
          // ====================================================

          Text(
            context.tr('profile'),
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: darkText,
            ),
          ),

          const SizedBox(height: 25),

          // ====================================================
          // USER CARD
          // ====================================================

          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: cardSurfaceColor,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 15,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Row(
              children: [
                // ==================================================
                // AVATAR
                // ==================================================

                CircleAvatar(
                  radius: 32,
                  backgroundColor: const Color(0xFFEFF6FF),
                  backgroundImage: hasLocalPhoto
                      ? FileImage(File(localPhotoPath!))
                      : null,
                  child: !hasLocalPhoto
                      ? const Icon(
                          Icons.person,
                          size: 32,
                          color: primaryBlue,
                        )
                      : null,
                ),

                const SizedBox(width: 15),

                // ==================================================
                // USER INFORMATION
                // ==================================================

                Expanded(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text(
                        userName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                          color: darkText,
                        ),
                      ),

                      const SizedBox(height: 4),

                      Text(
                        userEmail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textDirection: TextDirection.ltr,
                        style: TextStyle(
                          color: secondaryText,
                          fontSize: 13,
                        ),
                      ),

                      if (joinedText != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          joinedText,
                          style: TextStyle(
                            color: secondaryText,
                            fontSize: 11.5,
                          ),
                        ),
                      ],

                      const SizedBox(height: 4),

                      // UID ـی ئەم هەژمارە. پێویستت پێی دەبێت بۆ
                      // ئەوەی خۆت وەک یەکەم Admin دیاری بکەیت لە
                      // Firebase Console (بڕوانە تێبینی AdminHomeScreen).
                      GestureDetector(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: user.uid));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('UID کۆپی کرا ✅'),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        },
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                'UID: ${user.uid}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textDirection: TextDirection.ltr,
                                style: TextStyle(
                                  color: secondaryText,
                                  fontSize: 10.5,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.copy_rounded,
                              size: 12,
                              color: secondaryText,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                IconButton(
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => EditProfileScreen(
                          currentName: userName,
                          currentPhotoPath: localPhotoPath,
                        ),
                      ),
                    );
                    // دوای گەڕانەوە، وێنەی خۆجێیی نوێ دەکەینەوە
                    // ئەگەر لە Edit Profile گۆڕدرابێت.
                    await _loadLocalPhoto();
                  },
                  icon: const Icon(
                    Icons.edit_outlined,
                    color: primaryBlue,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // ====================================================
          // SETTINGS
          // ====================================================

          _profileTile(
            context,
            icon: Icons.settings_outlined,
            title: context.tr('settings'),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const SettingsScreen(),
                ),
              );
            },
          ),

          // ====================================================
          // LANGUAGE
          // ====================================================

          // ====================================================
          // ADMIN PANEL (تەنها بۆ ئەدمین دەردەکەوێت)
          // ====================================================

          StreamBuilder<bool>(
            stream: isAdminStream(),
            builder: (context, snapshot) {
              if (snapshot.data != true) return const SizedBox.shrink();

              return StreamBuilder<int>(
                stream: pendingOrdersCountStream(),
                builder: (context, ordersSnapshot) {
                  final pendingCount = ordersSnapshot.data ?? 0;

                  return _profileTile(
                    context,
                    icon: Icons.admin_panel_settings_outlined,
                    title: 'Admin Panel',
                    iconColor: Colors.deepPurple,
                    badgeCount: pendingCount,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const AdminHomeScreen(),
                        ),
                      );
                    },
                  );
                },
              );
            },
          ),

          // ====================================================
          // PURCHASE HISTORY
          // ====================================================

          _profileTile(
            context,
            icon: Icons.receipt_long_outlined,
            title: 'کڕینەکانم',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const PurchaseHistoryScreen(),
                ),
              );
            },
          ),

          // ====================================================
          // LANGUAGE
          // ====================================================

          // ====================================================
          // THEME (ڕووناک / تاریک / وەک سیستەم)
          // ====================================================

          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeModeNotifier,
            builder: (context, mode, _) {
              final label = switch (mode) {
                ThemeMode.system => 'وەک سیستەم',
                ThemeMode.light => 'ڕووناک (Light)',
                ThemeMode.dark => 'تاریک (Dark)',
              };
              return _profileTile(
                context,
                icon: Icons.dark_mode_outlined,
                title: 'دۆخی ڕووکار — $label',
                onTap: () => showThemeModeSheet(context),
              );
            },
          ),

          _profileTile(
            context,
            icon: Icons.language_outlined,
            title: context.tr('language'),
            onTap: () {
              _showLanguageDialog(context);
            },
          ),

          // ====================================================
          // HELP
          // ====================================================

          _profileTile(
            context,
            icon: Icons.help_outline,
            title: context.tr('help'),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const HelpSupportScreen(),
                ),
              );
            },
          ),

          // ====================================================
          // ABOUT APP
          // ====================================================

          _profileTile(
            context,
            icon: Icons.info_outline,
            title: 'دەربارەی ئەپ',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const AboutAppScreen(),
                ),
              );
            },
          ),

          // ====================================================
          // LOGOUT
          // ====================================================

          _profileTile(
            context,
            icon: Icons.logout,
            title: context.tr('logout'),
            iconColor: Colors.red,
            titleColor: Colors.red,
            onTap: () {
              _showLogoutDialog(context);
            },
          ),

          const SizedBox(height: 18),

          Center(
            child: FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snapshot) {
                final version = snapshot.data?.version;
                if (version == null) return const SizedBox.shrink();
                return Text(
                  'وەشان $version',
                  style: TextStyle(
                    color: secondaryText,
                    fontSize: 11.5,
                  ),
                );
              },
            ),
          ),
        ],
          );
        },
      ),
    );
  }

  // ==========================================================
  // PROFILE TILE
  // ==========================================================

  Widget _profileTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    Color iconColor = primaryBlue,
    Color? titleColor,
    int? badgeCount,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.025),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: cardSurfaceColor,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 3,
          ),

          leading: Icon(
            icon,
            color: iconColor,
          ),

          title: Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: titleColor ?? darkText,
            ),
          ),

          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (badgeCount != null && badgeCount > 0)
                Container(
                  margin: const EdgeInsets.only(left: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  constraints: const BoxConstraints(minWidth: 22),
                  decoration: BoxDecoration(
                    color: errorColor,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    badgeCount > 99 ? '99+' : '$badgeCount',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              Icon(
                Icons.chevron_right,
                color: secondaryText,
              ),
            ],
          ),

          onTap: onTap,
        ),
      ),
    );
  }
}

// ============================================================
// SETTINGS
// ============================================================

/// لیستی هەڵبژاردنی دۆخی ڕووکار (سیستەم / ڕووناک / تاریک) —
/// لە پرۆفایلەوە بانگ دەکرێت.
void showThemeModeSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    backgroundColor: cardSurfaceColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (context) {
      return ValueListenableBuilder<ThemeMode>(
        valueListenable: themeModeNotifier,
        builder: (context, mode, _) {
          Widget option(ThemeMode m, IconData icon, String label) {
            return ListTile(
              leading: Icon(icon, color: primaryBlue),
              title: Text(label, style: TextStyle(color: darkText)),
              trailing: mode == m
                  ? const Icon(Icons.check_circle, color: primaryBlue)
                  : null,
              onTap: () {
                setThemeMode(m);
                Navigator.pop(context);
              },
            );
          }

          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
                Text(
                  'دۆخی ڕووکار',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: darkText,
                  ),
                ),
                const SizedBox(height: 8),
                option(
                  ThemeMode.system,
                  Icons.brightness_auto_rounded,
                  'وەک سیستەم',
                ),
                option(
                  ThemeMode.light,
                  Icons.light_mode_outlined,
                  'ڕووناک (Light)',
                ),
                option(
                  ThemeMode.dark,
                  Icons.dark_mode_outlined,
                  'تاریک (Dark)',
                ),
                const SizedBox(height: 10),
              ],
            ),
          );
        },
      );
    },
  );
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Widget _tile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    Color iconColor = primaryBlue,
    Color? titleColor,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.025),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: cardSurfaceColor,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 3,
          ),
          leading: Icon(icon, color: iconColor),
          title: Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: titleColor ?? darkText,
            ),
          ),
          trailing: Icon(
            Icons.chevron_right,
            color: secondaryText,
          ),
          onTap: onTap,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(title: const Text('ڕێکخستنەکان')),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          _tile(
            context,
            icon: Icons.lock_outline,
            title: 'گۆڕینی وشەی نهێنی',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const ChangePasswordScreen(),
                ),
              );
            },
          ),
          _tile(
            context,
            icon: Icons.privacy_tip_outlined,
            title: 'پاراستنی نهێنی (Privacy)',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const PrivacyPolicyScreen(),
                ),
              );
            },
          ),

          const SizedBox(height: 20),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'ناوچەی مەترسیدار',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: errorColor,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(height: 8),

          _tile(
            context,
            icon: Icons.delete_forever_outlined,
            iconColor: errorColor,
            titleColor: errorColor,
            title: 'سڕینەوەی هەژمار',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const DeleteAccountScreen(),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

// ============================================================
// CHANGE PASSWORD
// ============================================================

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final currentPasswordController = TextEditingController();
  final newPasswordController = TextEditingController();
  final confirmPasswordController = TextEditingController();

  bool isSaving = false;
  bool obscureCurrent = true;
  bool obscureNew = true;
  bool obscureConfirm = true;
  bool isSendingReset = false;

  Future<void> _sendResetEmail() async {
    final email = FirebaseAuth.instance.currentUser?.email;
    if (email == null) return;

    setState(() => isSendingReset = true);
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('لینکی گۆڕینی وشەی نهێنی نێردرا بۆ $email ✅'),
        ),
      );
    } on FirebaseAuthException catch (e) {
      final message = e.code == 'too-many-requests'
          ? 'هەوڵی زۆر — تکایە دواتر هەوڵبدەرەوە.'
          : 'نەتوانرا لینک بنێردرێت. تکایە دووبارە هەوڵ بدە.';
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } finally {
      if (mounted) setState(() => isSendingReset = false);
    }
  }

  @override
  void dispose() {
    currentPasswordController.dispose();
    newPasswordController.dispose();
    confirmPasswordController.dispose();
    super.dispose();
  }

  InputDecoration _decoration(String label, {required VoidCallback toggle,
      required bool obscure}) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: cardSurfaceColor,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      suffixIcon: IconButton(
        onPressed: toggle,
        icon: Icon(
          obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
          color: secondaryText,
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final current = currentPasswordController.text;
    final newPass = newPasswordController.text;
    final confirm = confirmPasswordController.text;

    if (current.isEmpty || newPass.isEmpty || confirm.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تکایە هەموو خانەکان پڕبکەرەوە.')),
      );
      return;
    }

    if (newPass.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('وشەی نهێنی نوێ دەبێت لانی کەم ٨ پیت بێت.'),
        ),
      );
      return;
    }

    if (!RegExp(r'''[!@#$%^&*(),.?":{}|<>_\-\\/\[\]+='`]''')
        .hasMatch(newPass)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'وشەی نهێنی نوێ دەبێت هێمایەکی تایبەتی هەبێت، وەک @ یان !',
          ),
        ),
      );
      return;
    }

    if (!RegExp(r'[A-Z]').hasMatch(newPass)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'وشەی نهێنی نوێ دەبێت لانیکەم یەک پیتی گەورە (A-Z) هەبێت.',
          ),
        ),
      );
      return;
    }

    if (newPass != confirm) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('وشەی نهێنی نوێ و دووپاتکردنەوەکەی وەک یەک نین.'),
        ),
      );
      return;
    }

    setState(() => isSaving = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      final email = user?.email;
      if (user == null || email == null) {
        throw Exception('بەکارهێنەر نەدۆزرایەوە.');
      }

      // پێش گۆڕینی وشەی نهێنی، پێویستە دووبارە پشتڕاستکردنەوە
      // (re-authenticate) بکرێت بە وشەی نهێنی ئێستا، وەک داوای
      // Firebase — ئەمە بۆ پاراستنی هەژمارە لە دژی کەسێک کە
      // مۆبایلی کراوەی بەکارهێنەرێکی تر بەدەستەوە گرتووە.
      final credential = EmailAuthProvider.credential(
        email: email,
        password: current,
      );
      await user.reauthenticateWithCredential(credential);
      await user.updatePassword(newPass);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('وشەی نهێنی بە سەرکەوتوویی گۆڕدرا ✅')),
      );
      Navigator.pop(context);
    } on FirebaseAuthException catch (e) {
      String message = 'هەڵەیەک ڕوویدا.';
      if (e.code == 'wrong-password' || e.code == 'invalid-credential') {
        message = 'وشەی نهێنی ئێستا هەڵەیە.';
      } else if (e.code == 'weak-password') {
        message = 'وشەی نهێنی نوێ لاوازە.';
      } else if (e.code == 'too-many-requests') {
        message = 'هەوڵی زۆر — تکایە دواتر هەوڵبدەرەوە.';
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('هەڵە: $e')),
      );
    } finally {
      if (mounted) setState(() => isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(title: const Text('گۆڕینی وشەی نهێنی')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: currentPasswordController,
            obscureText: obscureCurrent,
            decoration: _decoration(
              'وشەی نهێنی ئێستا',
              obscure: obscureCurrent,
              toggle: () =>
                  setState(() => obscureCurrent = !obscureCurrent),
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(
              onPressed:
                  (isSendingReset || isSaving) ? null : _sendResetEmail,
              child: isSendingReset
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('وشەی نهێنیت لەبیرکردووە؟'),
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: newPasswordController,
            obscureText: obscureNew,
            decoration: _decoration(
              'وشەی نهێنی نوێ',
              obscure: obscureNew,
              toggle: () => setState(() => obscureNew = !obscureNew),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: confirmPasswordController,
            obscureText: obscureConfirm,
            decoration: _decoration(
              'دووپاتکردنەوەی وشەی نهێنی نوێ',
              obscure: obscureConfirm,
              toggle: () =>
                  setState(() => obscureConfirm = !obscureConfirm),
            ),
          ),
          const SizedBox(height: 24),
          GradientButton(
            label: 'پاشەکەوتکردن',
            isLoading: isSaving,
            onPressed: isSaving ? null : _submit,
            height: 52,
          ),
        ],
      ),
    );
  }
}

// ============================================================
// DELETE ACCOUNT
// ============================================================

class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  final passwordController = TextEditingController();
  bool obscure = true;
  bool isDeleting = false;

  @override
  void dispose() {
    passwordController.dispose();
    super.dispose();
  }

  /// سڕینەوەی هەموو بەڵگەنامەکانی کۆلێکشنێک بۆ بەکارهێنەری
  /// ئێستا (وەک Library، Favorites، Cart)، پێش سڕینەوەی
  /// هەژمارەکە خۆی.
  Future<void> _deleteSubcollection(
    CollectionReference<Map<String, dynamic>>? ref,
  ) async {
    if (ref == null) return;
    final snap = await ref.get();
    final batch = FirebaseFirestore.instance.batch();
    for (final doc in snap.docs) {
      batch.delete(doc.reference);
    }
    await batch.commit();
  }

  Future<void> _confirmAndDelete() async {
    final password = passwordController.text;
    if (password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تکایە وشەی نهێنیت بنووسە.')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('دڵنیابوونەوەی کۆتایی'),
        content: const Text(
          'ئەم کردارە ناگەڕێتەوە. هەژمارەکەت، پەرتووکخانەکەت، '
          'دڵخوازەکان و سەبەتەی کڕینت بە تەواوی دەسڕدرێنەوە. '
          'دڵنیایت؟',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('پاشگەزبوونەوە'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'بەڵێ، بیسڕەوە',
              style: TextStyle(color: errorColor, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => isDeleting = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      final email = user?.email;
      if (user == null || email == null) {
        throw Exception('بەکارهێنەر نەدۆزرایەوە.');
      }

      // پێش سڕینەوە، پێویستە دووبارە پشتڕاستکردنەوە بکرێت —
      // وەک داوای Firebase بۆ کردارە هەستیارەکان.
      final credential = EmailAuthProvider.credential(
        email: email,
        password: password,
      );
      await user.reauthenticateWithCredential(credential);

      // سڕینەوەی داتای Firestore ـی بەکارهێنەر پێش سڕینەوەی
      // هەژمارەکەی خۆی (⚠️ تۆمارەکانی 'orders' وەک خۆیان
      // دەمێننەوە بۆ پاراستنی مێژووی بازرگانی).
      await _deleteSubcollection(_libraryRef());
      await _deleteSubcollection(_favoritesRef());
      await _deleteSubcollection(_cartRef());
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .delete();

      await user.delete();

      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    } on FirebaseAuthException catch (e) {
      String message = 'هەڵەیەک ڕوویدا.';
      if (e.code == 'wrong-password' || e.code == 'invalid-credential') {
        message = 'وشەی نهێنی هەڵەیە.';
      } else if (e.code == 'too-many-requests') {
        message = 'هەوڵی زۆر — تکایە دواتر هەوڵبدەرەوە.';
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('هەڵە: $e')),
      );
    } finally {
      if (mounted) setState(() => isDeleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(title: const Text('سڕینەوەی هەژمار')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: errorColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: errorColor),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'ئەم کردارە هەمیشەیی و ناگەڕێتەوەیە. هەموو '
                    'داتاکانت (پەرتووکخانە، دڵخوازەکان، سەبەتە) '
                    'دەسڕدرێنەوە.',
                    style: TextStyle(color: errorColor, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          TextField(
            controller: passwordController,
            obscureText: obscure,
            decoration: InputDecoration(
              labelText: 'وشەی نهێنیت بنووسە بۆ دڵنیابوونەوە',
              filled: true,
              fillColor: cardSurfaceColor,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              suffixIcon: IconButton(
                onPressed: () => setState(() => obscure = !obscure),
                icon: Icon(
                  obscure
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  color: secondaryText,
                ),
              ),
            ),
          ),
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: isDeleting ? null : _confirmAndDelete,
              icon: isDeleting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.delete_forever_outlined),
              label: Text(
                isDeleting ? 'سڕینەوە...' : 'سڕینەوەی هەژمار بۆ هەمیشە',
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: errorColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// HELP & SUPPORT
// ============================================================

// ============================================================
// ABOUT APP
// ============================================================

class AboutAppScreen extends StatelessWidget {
  const AboutAppScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(title: const Text('دەربارەی ئەپ')),
      body: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          Center(
            child: Column(
              children: [
                Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    gradient: brandGradient,
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: softShadow(opacity: 0.15, blur: 20),
                  ),
                  child: const Icon(
                    Icons.school_rounded,
                    color: Colors.white,
                    size: 42,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'ZNAR Academy',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: darkText,
                  ),
                ),
                const SizedBox(height: 4),
                FutureBuilder<PackageInfo>(
                  future: PackageInfo.fromPlatform(),
                  builder: (context, snapshot) {
                    final version = snapshot.data?.version;
                    final buildNumber = snapshot.data?.buildNumber;
                    final label = version == null
                        ? '...'
                        : (buildNumber == null || buildNumber.isEmpty
                            ? version
                            : '$version+$buildNumber');
                    return Text(
                      'وەشان $label',
                      style: TextStyle(color: secondaryText, fontSize: 13),
                    );
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 28),

          Container(
            padding: const EdgeInsets.all(18),
            decoration: softCardDecoration(),
            child: Text(
              'ZNAR Academy پلاتفۆرمێکی ئەکادیمییە بۆ قوتابی و مامۆستایانی زانکۆ، بۆ بەڵاوکردنەوە و کڕینی سیمینار، ڕاپۆرت، توێژینەوە، و تێمپلەیتی ئەکادیمی بە زمانی کوردی، عەرەبی و ئینگلیزی.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: secondaryText,
                fontSize: 13.5,
                height: 1.7,
              ),
            ),
          ),

          const SizedBox(height: 22),

          _infoTile(
            icon: Icons.privacy_tip_outlined,
            title: 'سیاسەتی تایبەتمەندی',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const PrivacyPolicyScreen(),
                ),
              );
            },
          ),
          _infoTile(
            icon: Icons.support_agent_rounded,
            title: 'پشتگیری و یارمەتی',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const HelpSupportScreen(),
                ),
              );
            },
          ),

          const SizedBox(height: 26),

          Center(
            child: Text(
              '© ${DateTime.now().year} ZNAR Academy. هەموو مافەکان پارێزراون.',
              style: TextStyle(color: secondaryText, fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoTile({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: softCardDecoration(),
      child: ListTile(
        leading: Icon(icon, color: primaryBlue),
        title: Text(title, style: TextStyle(fontWeight: FontWeight.w600)),
        trailing: Icon(Icons.chevron_right, color: secondaryText),
        onTap: onTap,
      ),
    );
  }
}

class HelpSupportScreen extends StatelessWidget {
  const HelpSupportScreen({super.key});

  static const String whatsappNumber = '9647507305828';
  static const String supportEmail = 'znaridrees@gmail.com';

  Future<void> _openWhatsApp(BuildContext context) async {
    final uri = Uri.parse('https://wa.me/$whatsappNumber');
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('نەتوانرا واتساپ بکرێتەوە.')),
      );
    }
  }

  Future<void> _openEmail(BuildContext context) async {
    final uri = Uri(
      scheme: 'mailto',
      path: supportEmail,
      query: 'subject=${Uri.encodeComponent('پشتگیری ZNAR Academy')}',
    );
    final launched = await launchUrl(uri);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('نەتوانرا ئیمەیل بکرێتەوە.')),
      );
    }
  }

  Widget _contactTile({
    required BuildContext context,
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: softCardDecoration(),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 6,
        ),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color),
        ),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Directionality(
          textDirection: TextDirection.ltr,
          child: Text(
            subtitle,
            textAlign: TextAlign.left,
            style: TextStyle(color: secondaryText, fontSize: 13),
          ),
        ),
        trailing: Icon(Icons.chevron_right, color: secondaryText),
        onTap: onTap,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(title: const Text('هاریکاری')),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Text(
            'پەیوەندیمان پێوە بکە',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: darkText,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'ئەگەر پرسیار یان کێشەیەکت هەبوو، پەیوەندیمان پێوە بکە '
            'لە ڕێگەی یەکێک لەمانەوە:',
            style: TextStyle(color: secondaryText, fontSize: 13.5),
          ),
          const SizedBox(height: 20),

          _contactTile(
            context: context,
            icon: Icons.chat_bubble_rounded,
            color: const Color(0xFF25D366),
            title: 'واتساپ',
            subtitle: '+964 750 730 5828',
            onTap: () => _openWhatsApp(context),
          ),

          _contactTile(
            context: context,
            icon: Icons.email_rounded,
            color: primaryBlue,
            title: 'ئیمەیل',
            subtitle: supportEmail,
            onTap: () => _openEmail(context),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// PRIVACY POLICY
// ============================================================

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(title: const Text('پاراستنی نهێنی')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'ئێمە لە ZNAR Academy گرنگی زۆر بە پاراستنی زانیاری '
            'کەسیت دەدەین. ئەم پەڕەیە ڕوونکردنەوەیەکی کورتە '
            'سەبارەت بەوەی چ زانیارییەک کۆدەکەینەوە و چۆن '
            'بەکاریدەهێنین.',
            style: TextStyle(fontSize: 14, height: 1.7, color: darkText),
          ),
          SizedBox(height: 18),
          Text(
            'زانیارییەک کۆدەکرێتەوە',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          SizedBox(height: 6),
          Text(
            '• ناو و ئیمەیل، بۆ دروستکردنی هەژمار\n'
            '• وێنەی پرۆفایل (ئارەزوومەندانە)\n'
            '• مێژووی کڕین و بەرهەمە کڕدراوەکان\n'
            '• دڵخوازەکان و سەبەتەی کڕین',
            style: TextStyle(fontSize: 14, height: 1.7, color: secondaryText),
          ),
          SizedBox(height: 18),
          Text(
            'چۆن بەکاردەهێنرێت',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          SizedBox(height: 6),
          Text(
            'زانیارییەکانت تەنها بۆ کارکردنی ئەپەکە بەکاردەهێنرێن — '
            'وەک پشتڕاستکردنەوەی کڕین، پاراستنی پەرتووکخانەکەت، و '
            'باشترکردنی ئەزموونی بەکارهێنان. هیچ زانیارییەکی کەسیت '
            'بۆ لایەنی سێیەم نافرۆشرێت.',
            style: TextStyle(fontSize: 14, height: 1.7, color: secondaryText),
          ),
          SizedBox(height: 18),
          Text(
            'پەیوەندیکردن',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          SizedBox(height: 6),
          Text(
            'ئەگەر پرسیارێکت هەبوو سەبارەت بە نهێنی زانیارییەکانت، '
            'دەتوانیت پەیوەندیمان پێوە بکەیت لە ڕێگەی پشتگیریی ناو '
            'ئەپەکە.',
            style: TextStyle(fontSize: 14, height: 1.7, color: secondaryText),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// EDIT PROFILE
// ============================================================

class EditProfileScreen extends StatefulWidget {
  final String currentName;
  final String? currentPhotoPath;

  const EditProfileScreen({
    super.key,
    required this.currentName,
    this.currentPhotoPath,
  });

  @override
  State<EditProfileScreen> createState() =>
      _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final TextEditingController nameController;
  bool isLoading = false;

  bool isSavingPhoto = false;
  String? localPhotoPath;

  @override
  void initState() {
    super.initState();
    nameController = TextEditingController(text: widget.currentName);
    localPhotoPath = widget.currentPhotoPath;
  }

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  // ==========================================================
  // PICK & SAVE PROFILE PHOTO (خۆجێیی، وەک واتساپ)
  // ==========================================================
  // وێنەکە کۆپی دەکرێت بۆ فۆڵدەری ناوخۆیی ئەپەکە لەسەر ئامێرەکە،
  // و ڕێچکەکەی خەزن دەکرێت لە SharedPreferences. هیچ کاتێک
  // وێنەکە بۆ هیچ سێرڤەر یان خزمەتگوزارییەکی دەرەکی نانێردرێت.

  Future<void> _pickAndSavePhotoLocally() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (isSavingPhoto) return;

    setState(() => isSavingPhoto = true);

    try {
      final picker = ImagePicker();
      final XFile? picked = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
        maxWidth: 800,
      );

      if (picked == null) return; // بەکارهێنەر پاشگەزبووەتەوە

      final appDir = await getApplicationDocumentsDirectory();
      final savedPath = '${appDir.path}/profile_photo_${user.uid}.jpg';

      // کۆپیکردنی وێنەکە بۆ فۆڵدەری ناوخۆیی
      await File(picked.path).copy(savedPath);

      // خەزنکردنی ڕێچکەکە لە SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'profile_photo_path_${user.uid}',
        savedPath,
      );

      if (!mounted) return;

      setState(() {
        localPhotoPath = savedPath;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('وێنەی پرۆفایل نوێکرایەوە ✅'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('هەڵەیەک ڕوویدا لە کاتی خەزنکردنی وێنە.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => isSavingPhoto = false);
    }
  }

  // ==========================================================
  // SAVE PROFILE
  // ==========================================================

  Future<void> _saveProfile() async {
    final newName = nameController.text.trim();


    if (newName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تکایە ناوێک بنووسە.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => isLoading = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      // نوێکردنەوەی ناو لە Firebase Authentication
      await user.updateDisplayName(newName);
      await user.reload();

      // نوێکردنەوەی ناو لە Cloud Firestore
      // (merge: true وادەکات تەنها فیلدی 'name' نوێ ببێتەوە،
      // بەبێ ئەوەی فیلدەکانی تر وەک uid/email/createdAt بسڕدرێنەوە)
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set(
        {'name': newName},
        SetOptions(merge: true),
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('زانیارییەکانت نوێکرانەوە ✅'),
          behavior: SnackBarBehavior.floating,
        ),
      );

      Navigator.pop(context);
    } on FirebaseException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('هەڵە: ${e.message ?? e.code}'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('هەڵەیەک ڕوویدا. تکایە دووبارە هەوڵ بدە.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: const Text('گۆڕینی زانیاری'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Center(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 92,
                    height: 92,
                    decoration: BoxDecoration(
                      gradient: localPhotoPath == null
                          ? brandGradient
                          : null,
                      shape: BoxShape.circle,
                      image: localPhotoPath != null
                          ? DecorationImage(
                              image: FileImage(File(localPhotoPath!)),
                              fit: BoxFit.cover,
                            )
                          : null,
                      boxShadow: [
                        BoxShadow(
                          color: primaryBlue.withValues(alpha: 0.25),
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: localPhotoPath == null
                        ? const Icon(
                            Icons.person,
                            size: 42,
                            color: Colors.white,
                          )
                        : (isSavingPhoto
                            ? Container(
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.35),
                                  shape: BoxShape.circle,
                                ),
                                child: const Center(
                                  child: SizedBox(
                                    width: 26,
                                    height: 26,
                                    child: CircularProgressIndicator(
                                      color: Colors.white,
                                      strokeWidth: 2.5,
                                    ),
                                  ),
                                ),
                              )
                            : null),
                  ),
                  Positioned(
                    bottom: -2,
                    right: -2,
                    child: GestureDetector(
                      onTap: isSavingPhoto ? null : _pickAndSavePhotoLocally,
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: cardSurfaceColor,
                          shape: BoxShape.circle,
                          boxShadow: softShadow(opacity: 0.15, blur: 8),
                        ),
                        child: const Icon(
                          Icons.camera_alt,
                          size: 16,
                          color: primaryBlue,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 32),

            _label('ناوی تەواو'),
            const SizedBox(height: 8),
            TextField(
              controller: nameController,
              decoration: _inputDecoration(
                hint: 'ناوت بنووسە',
                icon: Icons.person_outline,
              ),
            ),

            const SizedBox(height: 22),

            _label('ئیمەیڵ'),
            const SizedBox(height: 8),
            TextField(
              enabled: false,
              controller: TextEditingController(
                text: user?.email ?? '',
              ),
              textDirection: TextDirection.ltr,
              decoration: _inputDecoration(
                hint: 'ئیمەیڵ',
                icon: Icons.email_outlined,
              ).copyWith(
                fillColor: Colors.grey.shade100,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'گۆڕینی ئیمەیڵ لە ئێستادا پشتگیری نەکراوە.',
              style: TextStyle(
                color: secondaryText,
                fontSize: 12,
              ),
            ),

            const SizedBox(height: 36),

            GradientButton(
              label: 'خەزنکردن',
              isLoading: isLoading,
              onPressed: isLoading ? null : _saveProfile,
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// HELPERS
// ============================================================

Widget _label(String text) {
  return Text(
    text,
    style: TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.bold,
      color: darkText,
    ),
  );
}

InputDecoration _inputDecoration({
  required String hint,
  required IconData icon,
}) {
  return InputDecoration(
    hintText: hint,
    prefixIcon: Icon(icon),
    filled: true,
    fillColor: cardSurfaceColor,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(
        color: Colors.grey.shade200,
      ),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(
        color: Colors.grey.shade200,
      ),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(
        color: primaryBlue,
        width: 1.5,
      ),
    ),
  );
}

Widget _sectionTitle(String title) {
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 5,
        height: 20,
        margin: const EdgeInsets.only(left: 8),
        decoration: BoxDecoration(
          gradient: brandGradient,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
      Text(
        title,
        style: TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.bold,
          color: darkText,
          letterSpacing: 0.1,
        ),
      ),
    ],
  );
}