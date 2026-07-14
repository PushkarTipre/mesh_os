import 'dart:convert';

import 'package:mesh_core/mesh_core.dart';
import 'package:test/test.dart';

void main() {
  group('IdentityCard', () {
    test('encodes and decodes, verifying against the embedded key', () async {
      final identity = await NodeIdentity.generate();
      final encoded = await IdentityCard.encode(identity: identity, displayName: 'Pushkar');

      final card = await IdentityCard.decode(encoded);

      expect(card, isNotNull);
      expect(card!.displayName, equals('Pushkar'));
      expect(card.signingPublicKey.bytes, equals(identity.signingPublicKey.bytes));
      expect(card.agreementPublicKey.bytes, equals(identity.agreementPublicKey.bytes));
      expect(await card.resolveNodeId(), equals(identity.nodeId));
    });

    test('rejects a tampered display name', () async {
      final identity = await NodeIdentity.generate();
      final encoded = await IdentityCard.encode(identity: identity, displayName: 'Pushkar');

      final json = jsonDecode(encoded) as Map<String, dynamic>;
      json['displayName'] = 'NotPushkar';
      final tampered = jsonEncode(json);

      expect(await IdentityCard.decode(tampered), isNull);
    });

    test('rejects a card whose public key doesn\'t match its signature', () async {
      final identity = await NodeIdentity.generate();
      final impostor = await NodeIdentity.generate();
      final encoded = await IdentityCard.encode(identity: identity, displayName: 'Pushkar');

      final json = jsonDecode(encoded) as Map<String, dynamic>;
      json['signingPublicKey'] = base64Encode(impostor.signingPublicKey.bytes);
      final tampered = jsonEncode(json);

      expect(await IdentityCard.decode(tampered), isNull);
    });

    test('rejects an unsupported version', () async {
      final identity = await NodeIdentity.generate();
      final encoded = await IdentityCard.encode(identity: identity, displayName: 'Pushkar');

      final json = jsonDecode(encoded) as Map<String, dynamic>;
      json['v'] = 99;
      final tampered = jsonEncode(json);

      expect(await IdentityCard.decode(tampered), isNull);
    });

    test('never throws on garbage input', () async {
      expect(await IdentityCard.decode('not even json'), isNull);
      expect(await IdentityCard.decode('{}'), isNull);
      expect(await IdentityCard.decode(''), isNull);
      expect(await IdentityCard.decode('null'), isNull);
      expect(await IdentityCard.decode('[1,2,3]'), isNull);
    });

    test('rejects a display name over the length limit', () async {
      final identity = await NodeIdentity.generate();
      final tooLong = 'x' * (IdentityCard.maxDisplayNameBytes + 1);

      expect(
        () => IdentityCard.encode(identity: identity, displayName: tooLong),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
