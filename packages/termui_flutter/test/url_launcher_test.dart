import 'package:flutter_test/flutter_test.dart';
import 'package:termui_flutter/termui_flutter.dart';

void main() {
  group('URL Launcher Validation', () {
    test(
      'parseAllowedExternalUri and isAllowedExternalUrl allow valid http, https, and mailto URIs',
      () {
        expect(isAllowedExternalUrl('https://dart.dev/guides'), isTrue);
        expect(isAllowedExternalUrl('http://[::1]:8420/status'), isTrue);
        expect(
          isAllowedExternalUrl('mailto:team@flutter.dev?subject=Hi'),
          isTrue,
        );
        expect(
          parseAllowedExternalUri('mailto:dev@dart.dev')?.scheme,
          equals('mailto'),
        );
      },
    );

    test(
      'parseAllowedExternalUri and isAllowedExternalUrl reject empty hosts, mailto authorities, control chars, and unsafe schemes',
      () {
        expect(isAllowedExternalUrl('http://'), isFalse);
        expect(isAllowedExternalUrl('https://'), isFalse);
        expect(isAllowedExternalUrl('mailto:'), isFalse);
        expect(isAllowedExternalUrl('mailto://authority/user'), isFalse);
        expect(isAllowedExternalUrl('javascript:alert(1)'), isFalse);
        expect(isAllowedExternalUrl('data:text/html,hi'), isFalse);
        expect(isAllowedExternalUrl('blob:https://dart.dev/1'), isFalse);
        expect(isAllowedExternalUrl('vbscript:msgbox(1)'), isFalse);
        expect(isAllowedExternalUrl('file:///etc/passwd'), isFalse);
        expect(isAllowedExternalUrl('https://dart.dev/\x07bell'), isFalse);
        expect(parseAllowedExternalUri('javascript:alert(1)'), isNull);
      },
    );
  });
}
