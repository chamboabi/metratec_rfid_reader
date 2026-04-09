# Flutter Metratec RFID Reader

A cross-platform Flutter/Dart library for communicating with **Metratec UHF RFID readers** using the AT command protocol.

## Disclaimer

Depends on the work from Metratec, only the Web Implementation is written by me.

I am not affiliated with or endorsed by Metratec. This code builds upon preexisting work developed by Metratec; I am solely responsible for the implementation of the web interface.

## Features

- **Cross-platform** -- works on Web, Desktop (Linux, macOS, Windows), and Android
- **Multiple transport backends**:
  - **Web Serial API** -- browser-based serial communication (Chrome/Edge)
  - **Native Serial** -- desktop serial ports via `flutter_libserialport`
  - **TCP** -- network-connected readers via TCP sockets
  - **USB** -- Android USB-OTG via `usb_serial`
- **High-level API** -- inventory, read/write tags, configure power/region/antenna, heartbeat monitoring
- **Continuous inventory streaming** -- real-time tag scanning via Dart `Stream`
- **Typed exceptions** -- structured error handling with `ReaderException` hierarchy

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Your Application                        │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  UhfReaderAt  -- High-level reader API                      │
│  inventory(), readTag(), writeTag(), setOutputPower(), ...   │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  ParserAt  -- AT protocol parser                            │
│  Sends "CMD\r", expects OK/ERROR, prefix-based matching     │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  CommInterface  -- Abstract communication layer             │
│  ┌────────────┐ ┌──────────┐ ┌──────────┐ ┌─────────────┐  │
│  │ WebSerial  │ │  Serial  │ │   TCP    │ │    USB      │  │
│  │ (browser)  │ │ (desktop)│ │ (native) │ │  (Android)  │  │
│  └────────────┘ └──────────┘ └──────────┘ └─────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Installation

Add this package to your `pubspec.yaml`:

```yaml
dependencies:
  metratec_rfid_reader:
    git:
      url: <your-repo-url>
```

## Usage

### Imports

```dart
// Platform-independent API (reader, models, parser, exceptions)
import 'package:metratec_rfid_reader/metratec_rfid.dart';

// Platform-specific communication interfaces
// Exports WebSerialInterface on web, or SerialInterface/TcpInterface/UsbInterface on native
import 'package:metratec_rfid_reader/metratec_rfid_platform.dart';
```

### Web (Browser via Web Serial API)

```dart
final comm = WebSerialInterface(WebSerialSettings(baudrate: 115200));
final reader = UhfReaderAt(comm);

// Connect -- opens the browser's serial port picker
await reader.connect(onError: (e, stack) => print('Error: $e'));

// Get device info
final info = await reader.getDeviceInfo();
print(info);

// Run a single inventory
final results = await reader.inventory();
for (final result in results) {
  print('Tag EPC: ${result.tag.epc}, RSSI: ${result.tag.rssi}');
}

// Disconnect
await reader.disconnect();
```

### Desktop (Native Serial Port)

```dart
final comm = SerialInterface(SerialSettings('/dev/ttyUSB0', baudrate: 115200));
final reader = UhfReaderAt(comm);

await reader.connect(onError: (e, stack) => print('Error: $e'));
final results = await reader.inventory();
await reader.disconnect();
```

### Android (USB-OTG)

```dart
final comm = UsbInterface(UsbSettings(deviceId, baudrate: 115200));
final reader = UhfReaderAt(comm);

await reader.connect(onError: (e, stack) => print('Error: $e'));
final results = await reader.inventory();
await reader.disconnect();
```

### TCP (Network-Connected Reader)

```dart
final comm = TcpInterface(TcpSettings('192.168.1.100', 10001));
final reader = UhfReaderAt(comm);

await reader.connect(onError: (e, stack) => print('Error: $e'));
final results = await reader.inventory();
await reader.disconnect();
```

### Continuous Inventory

```dart
// Listen to the continuous inventory stream
reader.cinvStream.listen((List<UhfInventoryResult> round) {
  for (final result in round) {
    print('Tag: ${result.tag.epc} on antenna ${result.lastAntenna}');
  }
});

// Start continuous scanning
await reader.startContinuousInventory();

// ... tags stream in via cinvStream ...

// Stop scanning
await reader.stopContinuousInventory();
```

### Reading and Writing Tag Memory

```dart
// Read 4 words from EPC memory bank starting at word 2
final readResults = await reader.readTag('EPC', 2, 4);
for (final r in readResults) {
  print('EPC: ${r.epc}, OK: ${r.ok}, Data: ${r.data.toHexString()}');
}

// Write hex data to user memory bank
await reader.writeTag('USR', 0, 'DEADBEEF');
```

### Heartbeat (Connection Monitoring)

```dart
await reader.startHeartBeat(
  5, // seconds between heartbeats
  () => print('Heartbeat OK'),
  () => print('Reader connection lost!'),
);

// Later...
await reader.stopHeartBeat();
```

### Configuration

```dart
// Power
await reader.setOutputPower([20]); // Set to 20 dBm
final power = await reader.getOutputPower();

// Region
await reader.setRegion('ETSI');
final region = await reader.getRegion();

// Antenna
await reader.setInvAntenna(1);
final antenna = await reader.getInvAntenna();

// Q value (anti-collision)
await reader.setQ(4, 0, 15);

// Inventory settings (ONT, RSSI, TID, FastStart)
await reader.setInventorySettings(UhfInvSettings(false, true, true, false));

// Session and RF mode
await reader.setSession('0');
await reader.setRfMode(0);
```

### Tag Security

```dart
// Lock a memory bank
await reader.lockMembank('EPC', '00000000');

// Unlock a memory bank
await reader.unlockMembank('EPC', '00000000');

// Permanently kill a tag (irreversible!)
await reader.killTag('00000000');
```

### Error Handling

The library uses a typed exception hierarchy:

```dart
try {
  await reader.inventory();
} on ReaderTimeoutException {
  print('No response from reader -- check connection');
} on ReaderNoTagsException {
  print('No tags in range');
} on ReaderCommException {
  print('Communication error');
} on ReaderException catch (e) {
  print('Reader error: ${e.cause}');
}
```

### Raw AT Commands

For advanced use or debugging, you can send raw AT command strings:

```dart
final result = await reader.sendRawCommand('ATI');
print('OK: ${result.ok}');
for (final line in result.lines) {
  print(line);
}
```

## API Reference

### UhfReaderAt (Main Reader Class)

| Category | Method | Description |
|---|---|---|
| Connection | `connect()` | Connect to the reader |
| Connection | `disconnect()` | Disconnect from the reader |
| Connection | `isConnected()` | Check connection status |
| Identity | `getDeviceInfo()` | Get device identification (ATI) |
| Feedback | `playFeedback(id)` | Trigger beep/LED pattern |
| Inventory | `inventory()` | Single inventory scan |
| Inventory | `muxInventory()` | Multiplexed multi-antenna inventory |
| Inventory | `startContinuousInventory()` | Start continuous scanning |
| Inventory | `stopContinuousInventory()` | Stop continuous scanning |
| Inventory | `cinvStream` | Stream of continuous inventory results |
| Inventory | `getInventorySettings()` | Get ONT/RSSI/TID/FastStart config |
| Inventory | `setInventorySettings()` | Set inventory format |
| Power | `getOutputPower()` | Get power level(s) in dBm |
| Power | `setOutputPower()` | Set power level(s) |
| Region | `getRegion()` / `setRegion()` | Regulatory region (ETSI, FCC, ...) |
| Antenna | `getInvAntenna()` / `setInvAntenna()` | Active antenna port |
| Q Value | `getQ()` / `setQ()` | Anti-collision Q parameter |
| Session | `getSession()` / `setSession()` | Gen2 session |
| RF Mode | `getRfMode()` / `setRfMode()` | RF modulation mode |
| Tag R/W | `readTag()` | Read from tag memory bank |
| Tag R/W | `writeTag()` | Write to tag memory bank |
| Mask | `setByteMask()` / `clearByteMask()` | Inventory filter mask |
| Lock | `lockMembank()` / `unlockMembank()` | Lock/unlock memory bank |
| Kill | `killTag()` | Permanently disable a tag |
| Heartbeat | `startHeartBeat()` / `stopHeartBeat()` | Connection monitoring |
| Reset | `resetReader()` | Hardware reset |
| Raw | `sendRawCommand()` | Send arbitrary AT command string |

### Communication Interfaces

| Class | Platform | Backend |
|---|---|---|
| `WebSerialInterface` | Web (Chrome/Edge) | Browser Web Serial API |
| `SerialInterface` | Linux, macOS, Windows | `flutter_libserialport` |
| `TcpInterface` | All native | `dart:io` Socket |
| `UsbInterface` | Android | `usb_serial` |

### Exception Hierarchy

| Exception | When Thrown |
|---|---|
| `ReaderException` | Base class for all reader errors |
| `ReaderCommException` | Connection lost or write failure |
| `ReaderTimeoutException` | Command timed out with no response |
| `ReaderNoTagsException` | No tags found during inventory/read/write |
| `ReaderRangeException` | Value out of valid range |

## Example App

The `example/` directory contains a Flutter Web debug application with a terminal-style interface for interacting with a reader. It demonstrates all major features including inventory, configuration, and raw AT command sending.

To run it:

```bash
cd example
flutter run -d chrome
```

## Requirements

- Dart SDK `>=3.3.0 <4.0.0`
- Flutter SDK
- **Web**: Chrome or Edge (Web Serial API support required)
- **Desktop**: OS-level serial port drivers
- **Android**: USB-OTG support and `usb_serial` permissions
