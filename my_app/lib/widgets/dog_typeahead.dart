import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:picons/picons.dart';
import '../constants/app_colors.dart';
import '../models/dog.dart';

/// A single-select typeahead dropdown for choosing one dog.
class DogTypeahead extends StatefulWidget {
  final List<Dog> dogs;
  final String? selectedDogId;
  final ValueChanged<String?> onSelected;
  final String hintText;

  const DogTypeahead({
    super.key,
    required this.dogs,
    required this.selectedDogId,
    required this.onSelected,
    this.hintText = 'Search dogs...',
  });

  @override
  State<DogTypeahead> createState() => _DogTypeaheadState();
}

class _DogTypeaheadState extends State<DogTypeahead> with WidgetsBindingObserver {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  List<Dog> _filteredDogs = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _filteredDogs = widget.dogs;
    _focusNode.addListener(_onFocusChanged);
    // Set initial text if a dog is selected
    if (widget.selectedDogId != null) {
      final dog = widget.dogs.where((d) => d.id == widget.selectedDogId).firstOrNull;
      if (dog != null) {
        _controller.text = dog.name;
      }
    }
  }

  @override
  void didChangeMetrics() {
    // Rebuild the overlay when the keyboard appears / disappears so its
    // maxHeight is re-clamped to the visible area above the keyboard.
    _overlayEntry?.markNeedsBuild();
  }

  @override
  void didUpdateWidget(DogTypeahead oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedDogId != oldWidget.selectedDogId) {
      if (widget.selectedDogId == null) {
        _controller.clear();
      } else {
        final dog = widget.dogs.where((d) => d.id == widget.selectedDogId).firstOrNull;
        if (dog != null) {
          _controller.text = dog.name;
        }
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _removeOverlay();
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus) {
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
      _showOverlay();
    } else {
      _removeOverlay();
      // Restore selected dog name or clear
      if (widget.selectedDogId != null) {
        final dog = widget.dogs.where((d) => d.id == widget.selectedDogId).firstOrNull;
        if (dog != null) _controller.text = dog.name;
      } else {
        _controller.clear();
      }
    }
  }

  double _availableOverlayHeight(BuildContext overlayContext) {
    final renderBox = context.findRenderObject();
    if (renderBox is! RenderBox || !renderBox.attached) return 200;
    final mediaQuery = MediaQuery.of(overlayContext);
    final fieldPos = renderBox.localToGlobal(Offset.zero);
    final fieldBottom = fieldPos.dy + renderBox.size.height;
    final available = mediaQuery.size.height
        - mediaQuery.viewInsets.bottom
        - fieldBottom
        - 16;
    return available.clamp(120.0, 280.0);
  }

  void _filterDogs(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredDogs = widget.dogs;
      } else {
        _filteredDogs = widget.dogs
            .where((d) => d.name.toLowerCase().contains(query.toLowerCase()))
            .toList();
      }
    });
    _overlayEntry?.markNeedsBuild();
  }

  void _showOverlay() {
    _removeOverlay();
    final renderBox = context.findRenderObject() as RenderBox;
    final size = renderBox.size;

    _overlayEntry = OverlayEntry(
      builder: (overlayContext) => Positioned(
        width: size.width,
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          offset: Offset(0, size.height + 4),
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: _availableOverlayHeight(overlayContext)),
              child: _filteredDogs.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('No dogs found', style: TextStyle(color: Colors.grey)),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: _filteredDogs.length,
                      itemBuilder: (context, index) {
                        final dog = _filteredDogs[index];
                        final isSelected = dog.id == widget.selectedDogId;
                        return ListTile(
                          dense: true,
                          leading: _buildDogAvatar(dog, 16),
                          title: Text(dog.name),
                          trailing: isSelected
                              ? Icon(Icons.check, color: AppColors.primary, size: 18)
                              : null,
                          selected: isSelected,
                          onTap: () {
                            if (isSelected) {
                              widget.onSelected(null);
                            } else {
                              widget.onSelected(dog.id);
                            }
                            _focusNode.unfocus();
                          },
                        );
                      },
                    ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        decoration: InputDecoration(
          hintText: widget.hintText,
          prefixIcon: Picon(PiconsDuotone.dog, size: 20),
          suffixIcon: widget.selectedDogId != null
              ? IconButton(
                  icon: Picon(PiconsDuotone.x, size: 18),
                  onPressed: () {
                    widget.onSelected(null);
                    _controller.clear();
                    _focusNode.unfocus();
                  },
                )
              : Picon(PiconsDuotone.caretDown, size: 18),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),        ),
        onChanged: _filterDogs,
      ),
    );
  }

  static Widget _buildDogAvatar(Dog dog, double radius) {
    if (dog.profileImageUrl != null) {
      return CircleAvatar(
        radius: radius,
        backgroundImage: CachedNetworkImageProvider(dog.profileImageUrl!),
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: AppColors.primaryLight.withAlpha(40),
      child: Text(
        dog.name.isNotEmpty ? dog.name[0].toUpperCase() : '?',
        style: TextStyle(fontSize: radius * 0.8, color: AppColors.primary),
      ),
    );
  }
}

/// A multi-select typeahead for tagging multiple dogs.
class DogMultiSelectTypeahead extends StatefulWidget {
  final List<Dog> dogs;
  final Set<String> selectedDogIds;
  final ValueChanged<Set<String>> onChanged;
  final String hintText;

  const DogMultiSelectTypeahead({
    super.key,
    required this.dogs,
    required this.selectedDogIds,
    required this.onChanged,
    this.hintText = 'Search dogs to tag...',
  });

  @override
  State<DogMultiSelectTypeahead> createState() => _DogMultiSelectTypeaheadState();
}

class _DogMultiSelectTypeaheadState extends State<DogMultiSelectTypeahead> with WidgetsBindingObserver {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  List<Dog> _filteredDogs = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _filteredDogs = widget.dogs;
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void didChangeMetrics() {
    _overlayEntry?.markNeedsBuild();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _removeOverlay();
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  double _availableOverlayHeight(BuildContext overlayContext) {
    final renderBox = context.findRenderObject();
    if (renderBox is! RenderBox || !renderBox.attached) return 200;
    final mediaQuery = MediaQuery.of(overlayContext);
    final fieldPos = renderBox.localToGlobal(Offset.zero);
    final fieldBottom = fieldPos.dy + renderBox.size.height;
    final available = mediaQuery.size.height
        - mediaQuery.viewInsets.bottom
        - fieldBottom
        - 16;
    return available.clamp(120.0, 280.0);
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus) {
      _showOverlay();
    } else {
      _removeOverlay();
      _controller.clear();
      _filteredDogs = widget.dogs;
    }
  }

  void _filterDogs(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredDogs = widget.dogs;
      } else {
        _filteredDogs = widget.dogs
            .where((d) => d.name.toLowerCase().contains(query.toLowerCase()))
            .toList();
      }
    });
    _overlayEntry?.markNeedsBuild();
  }

  void _toggleDog(Dog dog) {
    final updated = Set<String>.from(widget.selectedDogIds);
    if (updated.contains(dog.id)) {
      updated.remove(dog.id);
    } else {
      updated.add(dog.id);
    }
    widget.onChanged(updated);
    _controller.clear();
    _filteredDogs = widget.dogs;
    _overlayEntry?.markNeedsBuild();
  }

  void _removeDog(String dogId) {
    final updated = Set<String>.from(widget.selectedDogIds);
    updated.remove(dogId);
    widget.onChanged(updated);
  }

  void _showOverlay() {
    _removeOverlay();
    final renderBox = context.findRenderObject() as RenderBox;
    final size = renderBox.size;

    _overlayEntry = OverlayEntry(
      builder: (overlayContext) => Positioned(
        width: size.width,
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          offset: Offset(0, size.height + 4),
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: _availableOverlayHeight(overlayContext)),
              child: _filteredDogs.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('No dogs found', style: TextStyle(color: Colors.grey)),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: _filteredDogs.length,
                      itemBuilder: (context, index) {
                        final dog = _filteredDogs[index];
                        final isSelected = widget.selectedDogIds.contains(dog.id);
                        return ListTile(
                          dense: true,
                          leading: _buildDogAvatar(dog, 16),
                          title: Text(dog.name),
                          trailing: isSelected
                              ? Icon(Icons.check_circle, color: AppColors.primary, size: 20)
                              : Icon(Icons.circle_outlined, color: Colors.grey[400], size: 20),
                          onTap: () => _toggleDog(dog),
                        );
                      },
                    ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  @override
  Widget build(BuildContext context) {
    final selectedDogs = widget.dogs.where((d) => widget.selectedDogIds.contains(d.id)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CompositedTransformTarget(
          link: _layerLink,
          child: TextField(
            controller: _controller,
            focusNode: _focusNode,
            decoration: InputDecoration(
              hintText: widget.hintText,
              prefixIcon: Picon(PiconsDuotone.magnifyingGlass, size: 20),
              suffixIcon: widget.selectedDogIds.isNotEmpty
                  ? Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Chip(
                        label: Text('${widget.selectedDogIds.length}'),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: EdgeInsets.zero,
                        labelPadding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                    )
                  : null,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),            ),
            onChanged: _filterDogs,
          ),
        ),
        if (selectedDogs.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: selectedDogs.map((dog) {
              return Chip(
                avatar: _buildDogAvatar(dog, 12),
                label: Text(dog.name, style: const TextStyle(fontSize: 13)),
                onDeleted: () => _removeDog(dog.id),
                deleteIconColor: Colors.grey[600],
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              );
            }).toList(),
          ),
        ],
      ],
    );
  }

  static Widget _buildDogAvatar(Dog dog, double radius) {
    if (dog.profileImageUrl != null) {
      return CircleAvatar(
        radius: radius,
        backgroundImage: CachedNetworkImageProvider(dog.profileImageUrl!),
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: AppColors.primaryLight.withAlpha(40),
      child: Text(
        dog.name.isNotEmpty ? dog.name[0].toUpperCase() : '?',
        style: TextStyle(fontSize: radius * 0.8, color: AppColors.primary),
      ),
    );
  }
}
