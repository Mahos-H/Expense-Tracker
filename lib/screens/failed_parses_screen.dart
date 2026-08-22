import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/db_helper.dart';
import '../models/failed_parse.dart';

class FailedParsesScreen extends StatefulWidget {
  const FailedParsesScreen({super.key});
  @override
  State<FailedParsesScreen> createState() => _FailedParsesScreenState();
}

class _FailedParsesScreenState extends State<FailedParsesScreen> {
  List<FailedParse> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await DbHelper.instance.getFailedParses();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Unparsed Messages')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? const Center(child: Text('Nothing to review'))
              : ListView.builder(
                  itemCount: _items.length,
                  itemBuilder: (context, i) {
                    final f = _items[i];
                    return Card(
                      child: ListTile(
                        title: Text(f.title),
                        subtitle: Text(
                          '${DateFormat('dd MMM yyyy, hh:mm a').format(f.smsDateTime)}\n${f.body ?? ''}',
                        ),
                        isThreeLine: true,
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            await DbHelper.instance.deleteFailedParse(f.id!);
                            _load();
                          },
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
