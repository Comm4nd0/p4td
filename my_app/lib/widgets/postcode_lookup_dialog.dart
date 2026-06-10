import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../models/postcode_address.dart';
import '../services/data_service.dart';

/// Shows a dialog that looks up UK addresses for a postcode (via the backend
/// proxy at /api/postcode/lookup/) and lets the user pick one. Returns the
/// chosen address as a single formatted string, or null if cancelled.
Future<String?> showPostcodeLookup(BuildContext context, DataService dataService) {
  return showDialog<String>(
    context: context,
    builder: (context) => _PostcodeLookupDialog(dataService: dataService),
  );
}

class _PostcodeLookupDialog extends StatefulWidget {
  final DataService dataService;
  const _PostcodeLookupDialog({required this.dataService});

  @override
  State<_PostcodeLookupDialog> createState() => _PostcodeLookupDialogState();
}

class _PostcodeLookupDialogState extends State<_PostcodeLookupDialog> {
  final _controller = TextEditingController();
  bool _loading = false;
  String? _error;
  List<PostcodeAddress> _results = [];
  bool _searched = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final postcode = _controller.text.trim();
    if (postcode.isEmpty) {
      setState(() => _error = 'Enter a postcode to search.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _searched = true;
    });
    try {
      final results = await widget.dataService.lookupPostcode(postcode);
      if (!mounted) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _results = [];
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Find vet address'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _controller,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.search,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Postcode',
                hintText: 'e.g. RG1 1AA',
                prefixIcon: const Picon(PiconsDuotone.mapPin),
                suffixIcon: IconButton(
                  icon: const Picon(PiconsDuotone.magnifyingGlass),
                  onPressed: _loading ? null : _search,
                ),
              ),
              onSubmitted: (_) => _search(),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))
            else if (_searched && _results.isEmpty)
              const Text('No addresses found for that postcode.')
            else if (_results.isNotEmpty)
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.4,
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _results.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final addr = _results[index];
                      return ListTile(
                        dense: true,
                        leading: const Picon(PiconsDuotone.house),
                        title: Text(addr.formatted),
                        onTap: () => Navigator.pop(context, addr.formatted),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
