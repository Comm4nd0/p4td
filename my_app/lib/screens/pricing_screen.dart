import 'package:flutter/material.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/customer_rate.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';

/// Pricing management for payment managers: the standard day-care and
/// boarding prices, plus per-customer rates (discounts). Blank customer
/// rates mean the standard price applies; per-dog overrides (set in the
/// admin site) beat both.
class PricingScreen extends StatefulWidget {
  const PricingScreen({super.key});

  @override
  State<PricingScreen> createState() => _PricingScreenState();
}

class _PricingScreenState extends State<PricingScreen> {
  final DataService _dataService = getIt<DataService>();
  BillingSettings? _settings;
  List<CustomerRate> _customers = [];
  bool _loading = true;
  bool _busy = false;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final settings = await _dataService.getBillingSettings();
      final customers = await _dataService.getCustomerRates();
      if (mounted) {
        setState(() {
          _settings = settings;
          _customers = customers;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _showError('Failed to load pricing: $e');
      }
    }
  }

  void _showError(Object message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$message'), backgroundColor: AppColors.error),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.success),
    );
  }

  Future<void> _editDefaults() async {
    final settings = _settings!;
    final dayController = TextEditingController(text: settings.dayCarePrice.toStringAsFixed(2));
    final boardingController =
        TextEditingController(text: settings.boardingPricePerNight.toStringAsFixed(2));
    final transportController =
        TextEditingController(text: settings.ownerTransportDiscount.toStringAsFixed(2));

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Standard prices'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: dayController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Daycare price per day', prefixText: '£'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: boardingController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Boarding price per night',
                  prefixText: '£',
                  helperText: 'Covers the whole stay — daycare on boarded days is not charged on top.',
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: transportController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Owner transport discount per day',
                  prefixText: '£',
                  helperText: 'Off the day rate when the owner both drops off and picks up. 0 = no discount.',
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Applies to invoices generated from now on; customers with their own rate below are unaffected.',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (confirmed != true) return;

    final day = double.tryParse(dayController.text.trim());
    final boarding = double.tryParse(boardingController.text.trim());
    final transport = double.tryParse(transportController.text.trim());
    if (day == null || day < 0 || boarding == null || boarding < 0 || transport == null || transport < 0) {
      _showError('Enter valid prices');
      return;
    }
    setState(() => _busy = true);
    try {
      final updated = await _dataService.updateBillingSettings(
        dayCarePrice: day,
        boardingPricePerNight: boarding,
        ownerTransportDiscount: transport,
      );
      if (mounted) {
        setState(() => _settings = updated);
        _showSuccess('Standard prices updated');
      }
    } catch (e) {
      if (mounted) _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editCustomer(CustomerRate customer) async {
    final dayController = TextEditingController(
        text: customer.daycareRate?.toStringAsFixed(2) ?? '');
    final boardingController = TextEditingController(
        text: customer.boardingRate?.toStringAsFixed(2) ?? '');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(customer.displayName),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: dayController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Daycare rate per day',
                prefixText: '£',
                hintText: 'Standard (£${_settings!.dayCarePrice.toStringAsFixed(2)})',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: boardingController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Boarding rate per night',
                prefixText: '£',
                hintText: 'Standard (£${_settings!.boardingPricePerNight.toStringAsFixed(2)})',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Leave a field blank to charge the standard price.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (confirmed != true) return;

    double? parseOrNull(String text) =>
        text.trim().isEmpty ? null : double.tryParse(text.trim());
    final dayText = dayController.text.trim();
    final boardingText = boardingController.text.trim();
    final day = parseOrNull(dayText);
    final boarding = parseOrNull(boardingText);
    if ((dayText.isNotEmpty && (day == null || day < 0)) ||
        (boardingText.isNotEmpty && (boarding == null || boarding < 0))) {
      _showError('Enter valid rates, or leave blank for the standard price');
      return;
    }

    setState(() => _busy = true);
    try {
      final updated = await _dataService.updateCustomerRates(
        customer.userId, daycareRate: day, boardingRate: boarding);
      if (mounted) {
        setState(() {
          customer.daycareRate = updated.daycareRate;
          customer.boardingRate = updated.boardingRate;
        });
        _showSuccess('${customer.displayName}\'s rates updated');
      }
    } catch (e) {
      if (mounted) _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.toLowerCase();
    final visible = _customers
        .where((c) =>
            query.isEmpty ||
            c.displayName.toLowerCase().contains(query) ||
            c.username.toLowerCase().contains(query) ||
            c.dogNames.any((d) => d.toLowerCase().contains(query)))
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Pricing')),
      body: _loading
          ? const Center(child: CircularProgressIndicator.adaptive())
          : RefreshIndicator.adaptive(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _buildDefaultsCard(),
                  const SizedBox(height: 16),
                  Text('Customer rates',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(
                    'Tap a customer to set their rates — blank means they pay the standard price.',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    decoration: InputDecoration(
                      hintText: 'Search customers or dogs',
                      prefixIcon: Picon(PiconsDuotone.magnifyingGlass, size: 20),
                      isDense: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onChanged: (value) => setState(() => _search = value),
                  ),
                  const SizedBox(height: 8),
                  if (visible.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text('No customers found',
                            style: TextStyle(color: Colors.grey[600])),
                      ),
                    )
                  else
                    ...visible.map(_buildCustomerTile),
                  const SizedBox(height: 24),
                ],
              ),
            ),
    );
  }

  Widget _buildDefaultsCard() {
    final settings = _settings!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Standard prices',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
                TextButton.icon(
                  onPressed: _busy ? null : _editDefaults,
                  icon: Picon(PiconsDuotone.pencilSimple, size: 16),
                  label: const Text('Edit'),
                ),
              ],
            ),
            _priceRow('Daycare (per day)', settings.dayCarePrice),
            _priceRow('Boarding (per night)', settings.boardingPricePerNight,
                warnIfZero: true),
            _priceRow('Owner transport discount (per day)', settings.ownerTransportDiscount),
          ],
        ),
      ),
    );
  }

  Widget _priceRow(String label, double price, {bool warnIfZero = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: TextStyle(color: Colors.grey[700]))),
          Text('£${price.toStringAsFixed(2)}',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: warnIfZero && price == 0 ? AppColors.error : null,
              )),
          if (warnIfZero && price == 0) ...[
            const SizedBox(width: 6),
            Picon(PiconsDuotone.warning, size: 16, color: AppColors.error),
          ],
        ],
      ),
    );
  }

  Widget _buildCustomerTile(CustomerRate customer) {
    final parts = <String>[
      if (customer.daycareRate != null)
        'Daycare £${customer.daycareRate!.toStringAsFixed(2)}',
      if (customer.boardingRate != null)
        'Boarding £${customer.boardingRate!.toStringAsFixed(2)}',
    ];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        title: Text(customer.displayName,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          [
            if (customer.dogNames.isNotEmpty) customer.dogNames.join(', '),
            parts.isEmpty ? 'Standard prices' : parts.join(' · '),
          ].join('\n'),
          style: const TextStyle(fontSize: 12),
        ),
        trailing: customer.hasCustomRate
            ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.info.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: AppColors.info.withValues(alpha: 0.5)),
                ),
                child: const Text('Custom',
                    style: TextStyle(
                        color: AppColors.info,
                        fontWeight: FontWeight.bold,
                        fontSize: 11)),
              )
            : null,
        onTap: _busy ? null : () => _editCustomer(customer),
      ),
    );
  }
}
