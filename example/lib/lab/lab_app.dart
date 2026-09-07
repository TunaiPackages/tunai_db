import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'lab_case.dart';
import 'lab_runner.dart';
import 'lab_suite.dart';

class TunaiDBLabApp extends StatelessWidget {
  const TunaiDBLabApp({super.key, this.runner});
  final LabRunner? runner;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'TunaiDB Test Lab',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff2459a6)),
      useMaterial3: true,
    ),
    home: LabScreen(runner: runner),
  );
}

class LabScreen extends StatefulWidget {
  const LabScreen({super.key, this.runner});
  final LabRunner? runner;
  @override
  State<LabScreen> createState() => _LabScreenState();
}

class _LabScreenState extends State<LabScreen> {
  late final LabRunner runner = widget.runner ?? LabRunner(createLabSuite());
  String category = 'All';
  bool crucialOnly = false;
  bool failuresOnly = false;
  @override
  void dispose() {
    if (widget.runner == null) runner.dispose();
    super.dispose();
  }

  List<LabCase> get selected => runner.cases
      .where(
        (c) =>
            (category == 'All' || c.category == category) &&
            (!crucialOnly || c.crucial),
      )
      .toList();
  String get report =>
      const JsonEncoder.withIndent('  ').convert(runner.report());
  Future<void> saveReport() async {
    try {
      final directory = Directory(
        '${(await getApplicationDocumentsDirectory()).path}/tunai_db_test_lab_reports',
      );
      await directory.create(recursive: true);
      final file = File(
        '${directory.path}/run_${DateTime.now().millisecondsSinceEpoch}.json',
      );
      await file.writeAsString(report);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: SelectableText('Report saved: ${file.path}')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save the test report: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: runner,
    builder: (context, _) {
      final results = runner.results;
      final passed = results.where((r) => r.status == LabStatus.passed).length;
      final failed = results.where((r) => r.status == LabStatus.failed).length;
      final completed = passed + failed;
      final visible = results
          .where(
            (r) =>
                selected.any((c) => c.id == r.test.id) &&
                (!failuresOnly || r.status == LabStatus.failed),
          )
          .toList();
      return Scaffold(
        appBar: AppBar(
          title: const Text('TunaiDB Test Lab'),
          actions: [
            IconButton(
              tooltip: 'Copy JSON report',
              onPressed: completed == 0
                  ? null
                  : () async {
                      await Clipboard.setData(ClipboardData(text: report));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Test report copied.')),
                        );
                      }
                    },
              icon: const Icon(Icons.copy_outlined),
            ),
            IconButton(
              tooltip: 'Save JSON report',
              onPressed: completed == 0 ? null : saveReport,
              icon: const Icon(Icons.save_alt),
            ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1150),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Real SQLite. Real assertions.',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Each test uses a uniquely named disposable database. Existing app databases are never opened. Known defects remain red until they are fixed.',
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          FilledButton.icon(
                            key: const Key('run-all'),
                            onPressed: runner.running
                                ? null
                                : () => runner.run(runner.cases),
                            icon: const Icon(Icons.play_arrow),
                            label: Text('Run all ${runner.cases.length} tests'),
                          ),
                          OutlinedButton(
                            onPressed: runner.running || selected.isEmpty
                                ? null
                                : () => runner.run(selected),
                            child: Text('Run selected (${selected.length})'),
                          ),
                          if (runner.running)
                            TextButton(
                              onPressed: runner.stopRequested
                                  ? null
                                  : runner.stopAfterCurrent,
                              child: Text(
                                runner.stopRequested
                                    ? 'Stopping after current test…'
                                    : 'Stop after current test',
                              ),
                            ),
                          Text(
                            '$passed passed  ·  $failed failed  ·  ${results.length - completed} not completed',
                            key: const Key('summary'),
                          ),
                        ],
                      ),
                      if (runner.running)
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: LinearProgressIndicator(),
                        ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final name in [
                            'All',
                            ...runner.cases.map((c) => c.category).toSet(),
                          ])
                            ChoiceChip(
                              label: Text(name),
                              selected: category == name,
                              onSelected: runner.running
                                  ? null
                                  : (_) => setState(() => category = name),
                            ),
                        ],
                      ),
                      Wrap(
                        spacing: 8,
                        children: [
                          FilterChip(
                            label: const Text('Crucial only'),
                            selected: crucialOnly,
                            onSelected: runner.running
                                ? null
                                : (v) => setState(() => crucialOnly = v),
                          ),
                          FilterChip(
                            label: const Text('Failures only'),
                            selected: failuresOnly,
                            onSelected: (v) => setState(() => failuresOnly = v),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: visible.isEmpty
                      ? const Center(
                          child: Text('No tests match these filters.'),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: visible.length,
                          itemBuilder: (context, index) =>
                              _ResultTile(result: visible[index]),
                        ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.result});
  final LabResult result;
  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (result.status) {
      LabStatus.pending => (
        Icons.radio_button_unchecked,
        Theme.of(context).colorScheme.outline,
      ),
      LabStatus.running => (
        Icons.hourglass_top,
        Theme.of(context).colorScheme.primary,
      ),
      LabStatus.passed => (Icons.check_circle_outline, Colors.green.shade700),
      LabStatus.failed => (
        Icons.error_outline,
        Theme.of(context).colorScheme.error,
      ),
    };
    return Card(
      child: ExpansionTile(
        leading: Icon(icon, color: color, semanticLabel: result.status.name),
        title: Text(result.test.title),
        subtitle: Text(
          '${result.test.category} · ${result.status.name.toUpperCase()}${result.test.crucial ? ' · CRUCIAL' : ''}${result.test.knownIssue != null ? ' · recorded issue' : ''}',
        ),
        trailing: result.status == LabStatus.running
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text('${result.elapsed.inMilliseconds} ms'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText('Test: ${result.test.id}'),
                  if (result.test.knownIssue case final String note)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text('Recorded issue: $note'),
                    ),
                  SelectableText(
                    result.detail.isEmpty
                        ? 'Run the test to see assertion results.'
                        : result.detail,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
