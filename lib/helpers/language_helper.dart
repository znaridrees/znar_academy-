import 'package:flutter/material.dart';
import '../localization/app_localizations.dart';

extension LocalizationExtension on BuildContext {
  String tr(String key) {
    return AppLocalizations.of(this).get(key);
  }
}