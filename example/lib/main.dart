import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logger/logger.dart';

// Import the package's public API
import 'package:metratec_rfid_reader/metratec_rfid.dart';
// Import WebSerialInterface directly (this example is web-only)
import 'package:metratec_rfid_reader/src/comm/web_serial_interface.dart';

void main() {
  runApp(const MetratecWebReaderApp());
}

class MetratecWebReaderApp extends StatelessWidget {
  const MetratecWebReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Metratec Web RFID Reader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1a1a2e),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        fontFamily: 'monospace',
      ),
      home: const ReaderDebugPage(),
    );
  }
}

// ── Message model for the chat view ─────────────────────────────────────────

enum MessageType { sent, received, info, error }

class ChatMessage {
  final String text;
  final MessageType type;
  final DateTime timestamp;

  ChatMessage(this.text, this.type) : timestamp = DateTime.now();
}

// ── Main Debug Page ─────────────────────────────────────────────────────────

class ReaderDebugPage extends StatefulWidget {
  const ReaderDebugPage({super.key});

  @override
  State<ReaderDebugPage> createState() => _ReaderDebugPageState();
}

class _ReaderDebugPageState extends State<ReaderDebugPage> {
  final Logger _logger = Logger();
  final TextEditingController _cmdController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];

  CommInterface? _commInterface;
  UhfReaderAt? _reader;
  bool _isConnected = false;
  bool _isBusy = false;
  bool _cinvRunning = false;
  StreamSubscription? _cinvSub;

  // ── Lifecycle ───────────────────────────────────────────────────────────

  @override
  void dispose() {
    _cinvSub?.cancel();
    _reader?.disconnect();
    _cmdController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  void _addMessage(String text, MessageType type) {
    setState(() {
      _messages.add(ChatMessage(text, type));
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _runCommand(String label, Future<void> Function() action) async {
    if (_isBusy) {
      _addMessage('Busy - wait for current command to finish', MessageType.info);
      return;
    }
    if (!_isConnected) {
      _addMessage('Not connected. Connect first.', MessageType.error);
      return;
    }

    setState(() => _isBusy = true);
    try {
      await action();
    } on ReaderTimeoutException catch (e) {
      _addMessage('TIMEOUT: $e', MessageType.error);
    } on ReaderNoTagsException catch (e) {
      _addMessage('NO TAGS: $e', MessageType.error);
    } on ReaderException catch (e) {
      _addMessage('READER ERROR: $e', MessageType.error);
    } catch (e, stack) {
      _addMessage('ERROR: $e', MessageType.error);
      _logger.e('Command "$label" failed', error: e, stackTrace: stack);
    } finally {
      setState(() => _isBusy = false);
    }
  }

  // ── Connection ──────────────────────────────────────────────────────────

  Future<void> _connect() async {
    if (_isConnected) {
      _addMessage('Already connected', MessageType.info);
      return;
    }

    if (!WebSerialInterface.isSupported) {
      _addMessage(
          'Web Serial API not supported!\n'
          'Use Chrome or Edge browser.',
          MessageType.error);
      return;
    }

    setState(() => _isBusy = true);
    _addMessage('Requesting serial port...', MessageType.info);

    try {
      _commInterface = WebSerialInterface(WebSerialSettings(baudrate: 115200));
      _reader = UhfReaderAt(_commInterface!);

      // Set up raw data logging for the chat view
      _reader!.onRawData = (data, isOutgoing) {
        if (isOutgoing) {
          _addMessage('>> $data', MessageType.sent);
        } else {
          _addMessage('<< $data', MessageType.received);
        }
      };

      bool connected = await _reader!.connect(
        onError: (error, stackTrace) {
          _addMessage('CONNECTION ERROR: $error', MessageType.error);
          _logger.e('Connection error', error: error, stackTrace: stackTrace);
        },
      );

      if (connected) {
        setState(() => _isConnected = true);
        _addMessage('Connected successfully!', MessageType.info);

        // Try to identify the device
        try {
          String info = await _reader!.getDeviceInfo();
          _addMessage('Device: $info', MessageType.info);
        } catch (e) {
          _addMessage(
              'Connected but could not identify device: $e', MessageType.info);
        }
      } else {
        _addMessage('Connection failed or cancelled', MessageType.error);
        _reader = null;
        _commInterface = null;
      }
    } catch (e, stack) {
      _addMessage('Failed to connect: $e', MessageType.error);
      _logger.e('Connect failed', error: e, stackTrace: stack);
      _reader = null;
      _commInterface = null;
    } finally {
      setState(() => _isBusy = false);
    }
  }

  Future<void> _disconnect() async {
    if (!_isConnected) return;

    setState(() => _isBusy = true);
    try {
      await _cinvSub?.cancel();
      _cinvSub = null;
      _cinvRunning = false;
      await _reader?.disconnect();
      _reader = null;
      _commInterface = null;
      setState(() => _isConnected = false);
      _addMessage('Disconnected', MessageType.info);
    } catch (e) {
      _addMessage('Error during disconnect: $e', MessageType.error);
    } finally {
      setState(() => _isBusy = false);
    }
  }

  // ── Raw command ─────────────────────────────────────────────────────────

  Future<void> _sendRawCommand() async {
    final cmd = _cmdController.text.trim();
    if (cmd.isEmpty) return;

    _cmdController.clear();

    await _runCommand('raw: $cmd', () async {
      final result = await _reader!.sendRawCommand(cmd);
      if (!result.ok) {
        _addMessage('Command returned ERROR', MessageType.error);
      }
    });
  }

  // ── RFID Operations ────────────────────────────────────────────────────

  Future<void> _doInventory() async {
    await _runCommand('inventory', () async {
      List<UhfInventoryResult> results = await _reader!.inventory();
      if (results.isEmpty) {
        _addMessage('Inventory: no tags found', MessageType.info);
      } else {
        _addMessage(
            'Inventory: ${results.length} tag(s) found', MessageType.info);
        for (var r in results) {
          _addMessage(
              '  EPC: ${r.tag.epc}'
              '${r.tag.tid.isNotEmpty ? " TID: ${r.tag.tid}" : ""}'
              '${r.tag.rssi != 0 ? " RSSI: ${r.tag.rssi}" : ""}',
              MessageType.info);
        }
      }
    });
  }

  Future<void> _doFeedback() async {
    await _runCommand('feedback', () async {
      bool success = await _reader!.playFeedback(1);
      if (success) {
        _addMessage(
            'Feedback (AT+FDB=1) sent - reader should beep/blink!',
            MessageType.info);
      }
    });
  }

  Future<void> _doGetPower() async {
    await _runCommand('get power', () async {
      List<int> power = await _reader!.getOutputPower();
      _addMessage('Output Power: ${power.join(", ")} dBm', MessageType.info);
    });
  }

  Future<void> _doSetPower() async {
    final controller = TextEditingController(text: '15');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set Output Power'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Power (dBm)',
            hintText: 'e.g. 15 or 10,15,20,25',
          ),
          keyboardType: TextInputType.text,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Set')),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;

    await _runCommand('set power', () async {
      List<int> vals =
          result.split(',').map((e) => int.parse(e.trim())).toList();
      await _reader!.setOutputPower(vals);
      _addMessage('Power set to: ${vals.join(", ")} dBm', MessageType.info);
    });
  }

  Future<void> _doGetRegion() async {
    await _runCommand('get region', () async {
      String region = await _reader!.getRegion();
      _addMessage('Region: $region', MessageType.info);
    });
  }

  Future<void> _doSetRegion() async {
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Set Region'),
        children: [
          for (var region in ['ETSI', 'FCC', 'ETSI_HIGH'])
            SimpleDialogOption(
              child: Text(region),
              onPressed: () => Navigator.pop(ctx, region),
            ),
        ],
      ),
    );
    if (result == null) return;

    await _runCommand('set region', () async {
      await _reader!.setRegion(result);
      _addMessage('Region set to: $result', MessageType.info);
    });
  }

  Future<void> _doGetQ() async {
    await _runCommand('get Q', () async {
      int q = await _reader!.getQ();
      _addMessage(
          'Q: $q (min: ${_reader!.currentMinQ}, max: ${_reader!.currentMaxQ})',
          MessageType.info);
    });
  }

  Future<void> _doGetAntenna() async {
    await _runCommand('get antenna', () async {
      int ant = await _reader!.getInvAntenna();
      _addMessage('Antenna: $ant', MessageType.info);
    });
  }

  Future<void> _doGetDeviceInfo() async {
    await _runCommand('device info', () async {
      String info = await _reader!.getDeviceInfo();
      _addMessage('Device Info:\n$info', MessageType.info);
    });
  }

  Future<void> _doToggleContinuousInventory() async {
    if (_cinvRunning) {
      await _runCommand('stop CINV', () async {
        await _reader!.stopContinuousInventory();
        _cinvSub?.cancel();
        _cinvSub = null;
        setState(() => _cinvRunning = false);
        _addMessage('Continuous inventory stopped', MessageType.info);
      });
    } else {
      await _runCommand('start CINV', () async {
        _cinvSub = _reader!.cinvStream.listen((results) {
          for (var r in results) {
            _addMessage(
                'CINV: EPC=${r.tag.epc}'
                '${r.tag.tid.isNotEmpty ? " TID=${r.tag.tid}" : ""}'
                '${r.tag.rssi != 0 ? " RSSI=${r.tag.rssi}" : ""}'
                ' ANT=${r.lastAntenna}',
                MessageType.info);
          }
        });

        await _reader!.startContinuousInventory();
        setState(() => _cinvRunning = true);
        _addMessage('Continuous inventory started', MessageType.info);
      });
    }
  }

  Future<void> _doGetInvSettings() async {
    await _runCommand('get inv settings', () async {
      UhfInvSettings settings = await _reader!.getInventorySettings();
      _addMessage('Inv Settings: $settings', MessageType.info);
    });
  }

  Future<void> _doResetReader() async {
    await _runCommand('reset', () async {
      await _reader!.resetReader();
      _addMessage('Reset command sent', MessageType.info);
    });
  }

  Future<void> _doGetSession() async {
    await _runCommand('get session', () async {
      String session = await _reader!.getSession();
      _addMessage('Session: $session', MessageType.info);
    });
  }

  Future<void> _doGetRfMode() async {
    await _runCommand('get RF mode', () async {
      int rfMode = await _reader!.getRfMode();
      _addMessage('RF Mode: $rfMode', MessageType.info);
    });
  }

  void _clearChat() {
    setState(() => _messages.clear());
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Metratec RFID Reader Debug'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Icon(Icons.circle,
                    size: 12,
                    color:
                        _isConnected ? Colors.greenAccent : Colors.redAccent),
                const SizedBox(width: 6),
                Text(_isConnected ? 'Connected' : 'Disconnected',
                    style: const TextStyle(fontSize: 14)),
              ],
            ),
          ),
          IconButton(
            icon: Icon(_isConnected ? Icons.usb_off : Icons.usb),
            tooltip: _isConnected ? 'Disconnect' : 'Connect',
            onPressed:
                _isBusy ? null : (_isConnected ? _disconnect : _connect),
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'Clear chat',
            onPressed: _clearChat,
          ),
        ],
      ),
      body: Row(
        children: [
          SizedBox(width: 220, child: _buildButtonPanel()),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                Expanded(child: _buildChatView()),
                const Divider(height: 1),
                _buildCommandInput(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Button Panel ────────────────────────────────────────────────────────

  Widget _buildButtonPanel() {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: ListView(
        padding: const EdgeInsets.all(8),
        children: [
          _sectionHeader('Connection'),
          _actionButton(
            icon: _isConnected ? Icons.usb_off : Icons.usb,
            label: _isConnected ? 'Disconnect' : 'Connect',
            onPressed: _isConnected ? _disconnect : _connect,
            color: _isConnected ? Colors.redAccent : Colors.greenAccent,
          ),
          const SizedBox(height: 4),
          _actionButton(
              icon: Icons.info_outline,
              label: 'Device Info (ATI)',
              onPressed: _doGetDeviceInfo),
          _actionButton(
              icon: Icons.restart_alt,
              label: 'Reset (AT+RST)',
              onPressed: _doResetReader,
              color: Colors.orangeAccent),
          const Divider(),
          _sectionHeader('Feedback'),
          _actionButton(
              icon: Icons.notifications_active,
              label: 'Beep (AT+FDB=1)',
              onPressed: _doFeedback,
              color: Colors.amberAccent),
          const Divider(),
          _sectionHeader('Inventory'),
          _actionButton(
              icon: Icons.search,
              label: 'Single Inventory',
              onPressed: _doInventory),
          _actionButton(
              icon: _cinvRunning ? Icons.stop : Icons.loop,
              label: _cinvRunning ? 'Stop CINV' : 'Start CINV',
              onPressed: _doToggleContinuousInventory,
              color: _cinvRunning ? Colors.redAccent : null),
          _actionButton(
              icon: Icons.settings,
              label: 'Inv Settings',
              onPressed: _doGetInvSettings),
          const Divider(),
          _sectionHeader('Configuration'),
          _actionButton(
              icon: Icons.bolt, label: 'Get Power', onPressed: _doGetPower),
          _actionButton(
              icon: Icons.bolt, label: 'Set Power', onPressed: _doSetPower),
          _actionButton(
              icon: Icons.public,
              label: 'Get Region',
              onPressed: _doGetRegion),
          _actionButton(
              icon: Icons.public,
              label: 'Set Region',
              onPressed: _doSetRegion),
          _actionButton(
              icon: Icons.tune, label: 'Get Q Value', onPressed: _doGetQ),
          _actionButton(
              icon: Icons.cell_tower,
              label: 'Get Antenna',
              onPressed: _doGetAntenna),
          _actionButton(
              icon: Icons.settings_input_component,
              label: 'Get Session',
              onPressed: _doGetSession),
          _actionButton(
              icon: Icons.radio,
              label: 'Get RF Mode',
              onPressed: _doGetRfMode),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Text(title,
          style: TextStyle(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
              fontSize: 13)),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    Color? color,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          icon: Icon(icon, size: 16, color: color),
          label: Text(label, style: const TextStyle(fontSize: 12)),
          style: ElevatedButton.styleFrom(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          ),
          onPressed:
              (_isBusy && label != 'Connect' && label != 'Disconnect')
                  ? null
                  : onPressed,
        ),
      ),
    );
  }

  // ── Chat View ───────────────────────────────────────────────────────────

  Widget _buildChatView() {
    if (_messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.terminal,
                size: 64,
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            Text('Connect to an RFID reader to start',
                style: TextStyle(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.5))),
            const SizedBox(height: 8),
            Text('Use the buttons on the left or type AT commands below',
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.3))),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(8),
      itemCount: _messages.length,
      itemBuilder: (context, index) => _buildMessageTile(_messages[index]),
    );
  }

  Widget _buildMessageTile(ChatMessage msg) {
    Color textColor;
    String prefix;
    switch (msg.type) {
      case MessageType.sent:
        textColor = Colors.cyanAccent;
        prefix = '';
      case MessageType.received:
        textColor = Colors.lightGreenAccent;
        prefix = '';
      case MessageType.info:
        textColor = Colors.white70;
        prefix = '[INFO] ';
      case MessageType.error:
        textColor = Colors.redAccent;
        prefix = '[ERR] ';
    }

    final timeStr =
        '${msg.timestamp.hour.toString().padLeft(2, '0')}:'
        '${msg.timestamp.minute.toString().padLeft(2, '0')}:'
        '${msg.timestamp.second.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: SelectableText.rich(
        TextSpan(children: [
          TextSpan(
              text: '[$timeStr] ',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.3), fontSize: 12)),
          TextSpan(
              text: '$prefix${msg.text}',
              style: TextStyle(color: textColor, fontSize: 13)),
        ]),
      ),
    );
  }

  // ── Command Input ───────────────────────────────────────────────────────

  Widget _buildCommandInput() {
    return Container(
      padding: const EdgeInsets.all(8),
      color: Theme.of(context).colorScheme.surface,
      child: Row(
        children: [
          const Text('AT> ',
              style: TextStyle(color: Colors.cyanAccent, fontSize: 14)),
          Expanded(
            child: TextField(
              controller: _cmdController,
              decoration: const InputDecoration(
                hintText: 'Type AT command (e.g., AT+INV, AT+FDB=1, ATI)',
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
              style: const TextStyle(fontSize: 14),
              onSubmitted: (_) => _sendRawCommand(),
              enabled: _isConnected && !_isBusy,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.send, size: 20),
            onPressed: (_isConnected && !_isBusy) ? _sendRawCommand : null,
            tooltip: 'Send command',
          ),
        ],
      ),
    );
  }
}
