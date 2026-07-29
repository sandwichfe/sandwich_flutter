part of 'emby_pc_detail_page.dart';

// 详情图片的全屏分页预览。
class _ArtworkPreviewDialog extends StatefulWidget {
  final List<_DetailImageRef> images;
  final int initialIndex;

  const _ArtworkPreviewDialog({
    required this.images,
    required this.initialIndex,
  });

  @override
  State<_ArtworkPreviewDialog> createState() => _ArtworkPreviewDialogState();
}

class _ArtworkPreviewDialogState extends State<_ArtworkPreviewDialog> {
  late final PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _showPage(int index) {
    if (index < 0 || index >= widget.images.length) return;
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final image = widget.images[_currentIndex];
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: EdgeInsets.zero,
      backgroundColor: const Color(0xF20F172A),
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              itemCount: widget.images.length,
              onPageChanged: (index) => setState(() => _currentIndex = index),
              itemBuilder:
                  (context, index) => Padding(
                    padding: const EdgeInsets.all(56),
                    child: InteractiveViewer(
                      minScale: 1,
                      maxScale: 5,
                      child: SizedBox.expand(
                        child: EmbyPcNetworkImage(
                          url: widget.images[index].url,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
            ),
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: IconButton.filled(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
              ),
            ),
            if (_currentIndex > 0)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: IconButton.filled(
                    tooltip: '上一张',
                    onPressed: () => _showPage(_currentIndex - 1),
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                ),
              ),
            if (_currentIndex < widget.images.length - 1)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: IconButton.filled(
                    tooltip: '下一张',
                    onPressed: () => _showPage(_currentIndex + 1),
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                ),
              ),
            SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Text(
                    '${image.label}  ${_currentIndex + 1}/${widget.images.length}',
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

