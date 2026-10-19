import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/generic_editor.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_toast.dart';
import 'memory/memory_books_controls.dart';

/// Editor for the text of a summary block, of the draft a regeneration left on
/// one, or of a new note.
///
/// The sheet a Memory Books entry or draft is edited in
/// (`MemoryEntryEditorSheet`) with the one field a block has, so the two tabs
/// of the Memory sheet edit the same way: a field list, then Cancel and Save.
class SummaryBlockEditorSheet extends StatefulWidget {
  final String initialValue;
  final String? placeholder;

  const SummaryBlockEditorSheet({
    super.key,
    required this.initialValue,
    this.placeholder,
  });

  /// The saved text, trimmed; null when the sheet was cancelled or dismissed.
  static Future<String?> show(
    BuildContext context, {
    required String title,
    String initialValue = '',
    String? placeholder,
  }) => GlazeBottomSheet.show<String>(
    context,
    title: title,
    child: SummaryBlockEditorSheet(
      initialValue: initialValue,
      placeholder: placeholder,
    ),
  );

  @override
  State<SummaryBlockEditorSheet> createState() =>
      _SummaryBlockEditorSheetState();
}

class _SummaryBlockEditorSheetState extends State<SummaryBlockEditorSheet> {
  late Map<String, dynamic> _values = {'content': widget.initialValue};

  void _save() {
    final content = (_values['content'] as String? ?? '').trim();
    if (content.isEmpty) {
      GlazeToast.show(context, 'memory_books_content_required'.tr());
      return;
    }
    Navigator.pop(context, content);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GenericEditor(
          item: _values,
          // The host bottom sheet already scrolls, and lays this out with an
          // unbounded height — a scroll view of its own would not resolve.
          scrollable: false,
          padding: EdgeInsets.zero,
          onChanged: (values) => _values = values,
          config: [
            GenericEditorSection(
              fields: [
                GenericEditorField(
                  key: 'content',
                  type: 'textarea',
                  rows: 8,
                  expandable: true,
                  label: 'label_content'.tr(),
                  placeholder: widget.placeholder,
                ),
              ],
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: MemoryEditorButton(
                  label: 'btn_cancel'.tr(),
                  onTap: () => Navigator.pop(context),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: MemoryEditorButton(
                  label: 'btn_save'.tr(),
                  emphasised: true,
                  onTap: _save,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
