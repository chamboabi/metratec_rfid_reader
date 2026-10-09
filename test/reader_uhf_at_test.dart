import 'package:flutter_test/flutter_test.dart';
import 'package:metratec_rfid_reader/metratec_rfid.dart';

import 'fake_comm.dart';

/// Replies shared by the tests: a PulsarLR with four ports, three active.
const _pulsarReplies = <String, List<String>>{
  'ATI': ['+SW: PULSAR_LR 1.4.2', '+HW: PULSAR_LR 2.0', '+SERIAL: 4711', 'OK'],
  'AT+INVS?': ['+INVS: 0,0,0,0', 'OK'],
  'AT+MUX?': ['+MUX: 1,2,3', 'OK'],
  'AT+MUX=1,2,3': ['OK'],
  'AT+MUX=2,4': ['OK'],
  'AT+CMINV': ['OK'],
  'AT+BINV': ['OK'],
  'AT+PWR?': ['+PWR: 20,20,20,0', 'OK'],
  'AT+PWR=20,20,20,0': ['OK'],
};

Future<(UhfReaderAt, FakeComm)> _connect(
    [Map<String, List<String>> replies = _pulsarReplies]) async {
  final comm = FakeComm(Map.of(replies));
  final reader = UhfReaderAt(comm);
  final ok = await reader.connect(onError: (e, s) => fail('$e'));
  expect(ok, isTrue);
  return (reader, comm);
}

void main() {
  group('UhfReaderModel.fromDeviceInfo', () {
    test('recognises the PulsarLR and the DeskID in any spelling', () {
      expect(UhfReaderModel.fromDeviceInfo('+HW: PULSAR_LR 2.0'),
          UhfReaderModel.pulsarLr);
      expect(UhfReaderModel.fromDeviceInfo('+SW: pulsar-lr 1.0'),
          UhfReaderModel.pulsarLr);
      expect(UhfReaderModel.fromDeviceInfo('+HW: DESKID_UHF_V2E 1'),
          UhfReaderModel.deskIdUhf);
      expect(UhfReaderModel.fromDeviceInfo('DeskID UHF v2'),
          UhfReaderModel.deskIdUhf);
    });

    test('falls back to unknown', () {
      expect(UhfReaderModel.fromDeviceInfo('+HW: DWARF_G2 1'),
          UhfReaderModel.unknown);
      expect(UhfReaderModel.fromDeviceInfo(''), UhfReaderModel.unknown);
    });

    test('knows the power range and mux support per model', () {
      expect(UhfReaderModel.deskIdUhf.maxPower, 9);
      expect(UhfReaderModel.pulsarLr.maxPower, 30);
      expect(UhfReaderModel.pulsarLr.supportsMux, isTrue);
      expect(UhfReaderModel.deskIdUhf.supportsMux, isFalse);
      expect(UhfReaderModel.unknown.supportsMux, isFalse);
    });
  });

  group('UhfReaderAt', () {
    test('getDeviceInfo records the reply and the model', () async {
      final (reader, _) = await _connect();
      expect(reader.readerModel, UhfReaderModel.unknown);

      final info = await reader.getDeviceInfo();

      expect(info, contains('PULSAR_LR'));
      expect(reader.lastDeviceInfo, info);
      expect(reader.readerModel, UhfReaderModel.pulsarLr);
      await reader.disconnect();
    });

    test('setMuxAntenna sends AT+MUX and caches the ports', () async {
      final (reader, comm) = await _connect();

      await reader.setMuxAntenna([1, 2, 3]);
      expect(comm.sent.last, 'AT+MUX=1,2,3');
      expect(reader.currentMuxAntenna, [1, 2, 3]);

      await reader.setMuxAntenna([2, 4]);
      expect(comm.sent.last, 'AT+MUX=2,4');
      expect(reader.currentMuxAntenna, [2, 4]);
      await reader.disconnect();
    });

    test('setMuxAntenna rejects an empty or invalid port list', () async {
      final (reader, comm) = await _connect();

      await expectLater(reader.setMuxAntenna([]), throwsA(isA<ReaderException>()));
      await expectLater(
          reader.setMuxAntenna([0, 1]), throwsA(isA<ReaderException>()));
      expect(comm.sent, isEmpty);
      await reader.disconnect();
    });

    test('setMuxAntenna surfaces the reader error', () async {
      final (reader, comm) = await _connect({
        'AT+MUX=1,2,3': ['+MUX: <NOT SUPPORTED>', 'ERROR'],
      });

      await expectLater(
          reader.setMuxAntenna([1, 2, 3]), throwsA(isA<ReaderException>()));
      expect(reader.currentMuxAntenna, [1]);
      expect(comm.sent, ['AT+MUX=1,2,3']);
      await reader.disconnect();
    });

    test('getMuxAntenna parses the port list', () async {
      final (reader, _) = await _connect();

      expect(await reader.getMuxAntenna(), [1, 2, 3]);
      expect(reader.currentMuxAntenna, [1, 2, 3]);
      await reader.disconnect();
    });

    test('startContinuousMuxInventory sends AT+CMINV and streams rounds',
        () async {
      final (reader, comm) = await _connect();
      final rounds = <List<UhfInventoryResult>>[];
      final sub = reader.cinvStream.listen(rounds.add);

      await reader.startContinuousMuxInventory();
      expect(comm.sent, ['AT+INVS?', 'AT+CMINV']);

      comm.emit([
        '+CMINV: E20000112233445566778899',
        '+CMINV: AABBCCDD',
        '+CMINV: <ROUND FINISHED, ANT=2>',
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(rounds, hasLength(1));
      expect(rounds.single.map((r) => r.tag.epc),
          ['E20000112233445566778899', 'AABBCCDD']);
      expect(rounds.single.map((r) => r.lastAntenna), [2, 2]);

      await reader.stopContinuousInventory();
      expect(comm.sent.last, 'AT+BINV');
      await sub.cancel();
      await reader.disconnect();
    });

    test('power is read and written per antenna port', () async {
      final (reader, comm) = await _connect();

      expect(await reader.getOutputPower(), [20, 20, 20, 0]);
      expect(reader.antennaCount, 4);

      await reader.setOutputPower([20, 20, 20, 0]);
      expect(comm.sent.last, 'AT+PWR=20,20,20,0');
      expect(reader.currentPower, [20, 20, 20, 0]);
      await reader.disconnect();
    });
  });
}
