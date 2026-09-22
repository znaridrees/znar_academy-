import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

class AppLocalizations {
  final Locale locale;

  AppLocalizations(this.locale);

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(
          context,
          AppLocalizations,
        ) ??
        AppLocalizations(const Locale('ku'));
  }

  String get(String key) {
    final language = locale.languageCode;

    return _translations[language]?[key] ??
        _translations['ku']?[key] ??
        key;
  }

  static const Map<String, Map<String, String>> _translations = {
    'ku': {
      'app_name': 'ZNAR Academy',
      'home': 'سەرەکی',
      'search': 'زڤرین',
      'library': 'پەرتوکخانە',
      'favorites': 'دڵخواز',
      'profile': 'پرۆفایل',
      'language': 'زمان',
      'kurdish': 'کوردی',
      'arabic': 'عەرەبی',
      'english': 'ئینگلیزی',
      'login': 'چوونا ژوور',
      'signup': 'دروستکرنا هەژمار',
      'logout': 'چوونا دەرێ',
      'settings': 'رێکخستن',
      'languageTitle': 'زمانێ ئەپ',
      'cancel': 'هەلوەشاندن',
      'student': 'قوتابی',
      'darkLight': 'ڕوون / تاریک',
      'help': 'هاریکاری',
},

    'ar': {
      'app_name': 'ZNAR Academy',
      'home': 'الرئيسية',
      'search': 'بحث',
      'library': 'مكتبتي',
      'favorites': 'المفضلة',
      'profile': 'الملف الشخصي',
      'language': 'اللغة',
      'kurdish': 'الكردية',
      'arabic': 'العربية',
      'english': 'الإنجليزية',
      'login': 'تسجيل الدخول',
      'signup': 'إنشاء حساب',
      'logout': 'تسجيل الخروج',
      'settings': 'الإعدادات',
      'languageTitle': 'لغة التطبيق',
      'cancel': 'إلغاء',
      'student': 'طالب',
      'darkLight': 'الوضع الفاتح / الداكن',
      'help': 'المساعدة',
  },

    'en': {
      'app_name': 'ZNAR Academy',
      'home': 'Home',
      'search': 'Search',
      'library': 'Library',
      'favorites': 'Favorites',
      'profile': 'Profile',
      'language': 'Language',
      'kurdish': 'Kurdish',
      'arabic': 'Arabic',
      'english': 'English',
      'login': 'Login',
      'signup': 'Sign Up',
      'logout': 'Logout',
      'settings': 'Settings',
      'languageTitle': 'App Language',
      'cancel': 'Cancel',
      'student': 'Student',
      'darkLight': 'Light / Dark Mode',
      'help': 'Help',
    },
  };
  
}

class AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    return ['ku', 'ar', 'en'].contains(locale.languageCode);
  }

  @override
  Future<AppLocalizations> load(Locale locale) async {
    return AppLocalizations(locale);
  }

  @override
  bool shouldReload(covariant AppLocalizationsDelegate old) {
    return false;
  }
}

class ZnarMaterialLocalizationsDelegate
    extends LocalizationsDelegate<MaterialLocalizations> {
  const ZnarMaterialLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    return ['ku', 'ar', 'en'].contains(locale.languageCode);
  }

  @override
  Future<MaterialLocalizations> load(Locale locale) {
    final materialLocale =
        locale.languageCode == 'ku' ? const Locale('ar') : locale;

    return GlobalMaterialLocalizations.delegate.load(materialLocale);
  }

  @override
  bool shouldReload(covariant ZnarMaterialLocalizationsDelegate old) {
    return false;
  }
}