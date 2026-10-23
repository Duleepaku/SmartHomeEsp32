// Prepares the Android project after `flutter create`.
//
//   flutter create --platforms=android --org com.example --project-name smart_home .
//   dart run tool/setup_android.dart
//
// What it does (safe to run many times):
//   * adds INTERNET / network permissions
//   * allows plain http:// (the ESP32 has no https)
//   * sets the app name to "Smart Home"
//   * copies the launcher icons from assets/icon/android/

import 'dart:io';

void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml');
  if (!manifest.existsSync()) {
    stderr.writeln('android/ folder not found. Run first:\n'
        '  flutter create --platforms=android --org com.example --project-name smart_home .');
    exit(1);
  }

  var xml = manifest.readAsStringSync();

  const perms = [
    'android.permission.INTERNET',
    'android.permission.ACCESS_NETWORK_STATE',
    'android.permission.ACCESS_WIFI_STATE',
  ];
  final missing = perms.where((p) => !xml.contains('"$p"')).toList();
  if (missing.isNotEmpty) {
    final lines = missing.map((p) => '    <uses-permission android:name="$p"/>').join('\n');
    final i = xml.indexOf('<application');
    xml = '${xml.substring(0, i)}${lines.trimLeft()}\n    ${xml.substring(i)}';
  }

  if (!xml.contains('usesCleartextTraffic')) {
    xml = xml.replaceFirst('<application', '<application\n        android:usesCleartextTraffic="true"');
  }

  xml = xml.replaceFirst(RegExp(r'android:label="[^"]*"'), 'android:label="Smart Home"');
  manifest.writeAsStringSync(xml);
  stdout.writeln('AndroidManifest.xml updated');

  // launcher icons
  final src = Directory('assets/icon/android');
  if (src.existsSync()) {
    var n = 0;
    for (final f in src.listSync(recursive: true).whereType<File>()) {
      final rel = f.path.substring(src.path.length + 1);
      final dest = File('android/app/src/main/res/$rel');
      dest.parent.createSync(recursive: true);
      f.copySync(dest.path);
      n++;
    }
    stdout.writeln('$n launcher icon files copied');
  }
  stdout.writeln('Done. Now run:  flutter build apk --release');
}
