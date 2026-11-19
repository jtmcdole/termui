import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show LicenseParagraph;
import 'package:material_ui/material_ui.dart';

import '../about/about_models.dart';
import '../about/about_view_model.dart';
import '../about/fterm_svg_baker.dart';
import '../file_drop_bridge.dart';
import '../font_loader.dart';
import '../workspace/fterm_workspace_controller.dart';
import 'fterm_overlays.dart';

/// Full-bleed Blender/GIMP-style splash hero painting `web/favicon.svg`'s
/// vector gradients, ambient radial glows, centered `f>` emblem, and baked-in
/// version badge.
final class FtermVersionedLogo extends StatelessWidget {
  /// Parsed vector scene derived from `web/favicon.svg`.
  final FtermLogoScene scene;

  /// Application version string (`kFtermBuildVersion`) rendered inside the SVG.
  final String version;

  /// Hero banner height in logical pixels.
  final double height;

  /// Callback closing the About overlay when the floating close button is tapped.
  final VoidCallback? onClose;

  /// Creates the full-bleed version-stamped `fterm` splash hero widget.
  const FtermVersionedLogo({
    super.key,
    required this.scene,
    required this.version,
    this.height = 298.0,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final badge = computeFtermVersionBadgeMetrics(version);
    return Semantics(
      label: 'fterm logo ${badge.label}',
      image: true,
      child: SizedBox(
        width: double.infinity,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: CustomPaint(
                painter: _FtermSplashPainter(scene: scene, badge: badge),
              ),
            ),
            const Positioned(
              left: 20,
              right: 20,
              bottom: 16,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'fterm',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFFF6FAFF),
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                  SizedBox(height: 3),
                  Text(
                    'Flutter terminal multiplexer & TermUI Caster client',
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Color(0xFFA6B4C8), fontSize: 11.5),
                  ),
                  SizedBox(height: 5),
                  Text(
                    kFtermMotto,
                    key: ValueKey('about-motto'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFFC8B273),
                      fontSize: 10.5,
                      fontStyle: FontStyle.italic,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ),
            ),
            if (onClose case final closeCallback?)
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  key: const ValueKey('about-close-button'),
                  onPressed: closeCallback,
                  icon: const Icon(
                    Icons.close,
                    size: 16,
                    color: Color(0xFFB8C4D4),
                  ),
                  tooltip: 'Close (Esc)',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

final class _FtermSplashPainter extends CustomPainter {
  static const double _viewBoxSize = 1024.0;
  static const double _emblemSize = 228.0;
  static const double _emblemTopOffset = -14.0;

  final FtermLogoScene scene;
  final FtermVersionBadgeMetrics badge;

  const _FtermSplashPainter({required this.scene, required this.badge});

  @override
  void paint(Canvas canvas, Size size) {
    _paintSplashBackdrop(canvas, size);

    final emblemScale = _emblemSize / _viewBoxSize;
    final emblemDx = (size.width - _emblemSize) / 2;

    canvas.save();
    canvas.translate(emblemDx, _emblemTopOffset);
    canvas.scale(emblemScale, emblemScale);

    _paintVectorGlyphs(canvas);
    _paintVersionBadge(canvas);

    canvas.restore();
  }

  void _paintSplashBackdrop(Canvas canvas, Size size) {
    final fullRect = Offset.zero & size;
    final bgShader = ui.Gradient.linear(
      Offset(size.width * 0.15, 0),
      Offset(size.width * 0.85, size.height),
      scene.bgStops,
      const [0.0, 0.5, 1.0],
    );
    canvas.drawRect(fullRect, Paint()..shader = bgShader);

    canvas.save();
    canvas.clipRect(fullRect);
    final blueAmbient = ui.Gradient.radial(
      Offset(size.width * 0.36, size.height * 0.38),
      size.height * 0.95,
      const [Color(0x2E5294E2), Color(0x005294E2)],
    );
    canvas.drawRect(fullRect, Paint()..shader = blueAmbient);

    final mintAmbient = ui.Gradient.radial(
      Offset(size.width * 0.64, size.height * 0.44),
      size.height * 0.88,
      const [Color(0x3D62D196), Color(0x0062D196)],
    );
    canvas.drawRect(fullRect, Paint()..shader = mintAmbient);
    canvas.restore();
  }

  void _paintVectorGlyphs(Canvas canvas) {
    final fShader = ui.Gradient.linear(
      const Offset(330, 220),
      const Offset(270, 800),
      scene.fStops,
    );
    final stemPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 86
      ..shader = fShader;
    canvas.drawPath(scene.fStemPath, stemPaint);

    final crossbarPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 78
      ..shader = fShader;
    canvas.drawPath(scene.fCrossbarPath, crossbarPaint);

    final glowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 106
      ..color = const Color(0x4762D196)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22);
    canvas.drawPath(scene.promptChevronPath, glowPaint);

    final gtShader = ui.Gradient.linear(
      const Offset(570, 360),
      const Offset(810, 660),
      scene.gtStops,
      const [0.0, 0.55, 1.0],
    );
    final gtPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 86
      ..shader = gtShader;
    canvas.drawPath(scene.promptChevronPath, gtPaint);
  }

  void _paintVersionBadge(Canvas canvas) {
    final rect = Rect.fromLTWH(
      badge.left,
      badge.top,
      badge.width,
      badge.height,
    );
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(badge.radius));
    canvas.drawRRect(rrect, Paint()..color = const Color(0xDB0D1017));
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..color = const Color(0x7A62D196),
    );

    final painter = TextPainter(
      text: TextSpan(
        text: badge.label,
        style: const TextStyle(
          color: Color(0xFF86F2B8),
          fontFamily: castPrimaryFontFamily,
          fontSize: 80,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    try {
      final maxTextWidth = badge.width - 56.0;
      final fitScale = painter.width > maxTextWidth
          ? maxTextWidth / painter.width
          : 1.0;
      final center = rect.center;
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.scale(fitScale, fitScale);
      painter.paint(canvas, Offset(-painter.width / 2, -painter.height / 2));
      canvas.restore();
    } finally {
      painter.dispose();
    }
  }

  @override
  bool shouldRepaint(_FtermSplashPainter oldDelegate) =>
      oldDelegate.scene != scene || oldDelegate.badge != badge;
}

/// Blender/GIMP-style splash About modal with centered full-bleed FTerm SVG
/// hero, two-column Project/Build deck, GitHub link, build date, and licenses.
final class FtermAboutOverlay extends StatelessWidget {
  /// Backing workspace coordinator.
  final FtermWorkspaceController workspace;

  /// Resolved overlay colors derived from the active terminal theme.
  final FtermOverlayPalette palette;

  /// External URL launcher used for the GitHub repository link.
  final UrlOpener onOpenUrl;

  /// Creates the [FtermAboutOverlay].
  const FtermAboutOverlay({
    super.key,
    required this.workspace,
    required this.palette,
    required this.onOpenUrl,
  });

  @override
  Widget build(BuildContext context) {
    final vm = workspace.aboutViewModel;
    return ListenableBuilder(
      listenable: vm,
      builder: (_, _) {
        final meta = vm.metadata;
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FtermVersionedLogo(
                key: const ValueKey('about-fterm-svg-logo'),
                scene: vm.logoScene,
                version: meta.version,
                onClose: workspace.dismissOverlay,
              ),
              Divider(height: 1, color: palette.border),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _AboutLowerDeck(
                      workspace: workspace,
                      metadata: meta,
                      palette: palette,
                      onOpenUrl: onOpenUrl,
                    ),
                    const SizedBox(height: 14),
                    Divider(height: 1, color: palette.border),
                    const SizedBox(height: 10),
                    Text(
                      kFtermCopyrightNotice,
                      key: const ValueKey('about-license-summary'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: palette.muted, fontSize: 10.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

final class _AboutLowerDeck extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermBuildMetadata metadata;
  final FtermOverlayPalette palette;
  final UrlOpener onOpenUrl;

  const _AboutLowerDeck({
    required this.workspace,
    required this.metadata,
    required this.palette,
    required this.onOpenUrl,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _AboutLinksColumn(
            workspace: workspace,
            palette: palette,
            onOpenUrl: onOpenUrl,
          ),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: _AboutBuildColumn(metadata: metadata, palette: palette),
        ),
      ],
    );
  }
}

final class _AboutLinksColumn extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final UrlOpener onOpenUrl;

  const _AboutLinksColumn({
    required this.workspace,
    required this.palette,
    required this.onOpenUrl,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'PROJECT',
          style: TextStyle(
            color: palette.muted,
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 8),
        Semantics(
          link: true,
          label: kFtermRepoUrl,
          child: _AboutActionLink(
            key: const ValueKey('about-github-link'),
            icon: Icons.open_in_new,
            label: kFtermRepoDisplayLabel,
            palette: palette,
            accent: true,
            onTap: () => onOpenUrl(Uri.parse(kFtermRepoUrl)),
          ),
        ),
        const SizedBox(height: 6),
        _AboutActionLink(
          key: const ValueKey('about-send-feedback'),
          icon: Icons.feedback_outlined,
          label: 'Send Feedback / Report Issue',
          palette: palette,
          accent: false,
          onTap: () => workspace.setOverlay(FtermOverlay.feedback),
        ),
        const SizedBox(height: 6),
        _AboutActionLink(
          key: const ValueKey('about-open-licenses'),
          icon: Icons.description_outlined,
          label: 'Open Source Licenses',
          palette: palette,
          accent: false,
          onTap: () => workspace.setOverlay(FtermOverlay.licenses),
        ),
      ],
    );
  }
}

final class _AboutActionLink extends StatelessWidget {
  final IconData icon;
  final String label;
  final FtermOverlayPalette palette;
  final bool accent;
  final VoidCallback onTap;

  const _AboutActionLink({
    super.key,
    required this.icon,
    required this.label,
    required this.palette,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = accent ? palette.accent : palette.foreground;
    final iconColor = accent ? palette.accent : palette.muted;
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: iconColor),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: textColor,
                  fontSize: 11.5,
                  decoration: accent ? TextDecoration.underline : null,
                  decorationColor: textColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _AboutBuildColumn extends StatelessWidget {
  final FtermBuildMetadata metadata;
  final FtermOverlayPalette palette;

  const _AboutBuildColumn({required this.metadata, required this.palette});

  @override
  Widget build(BuildContext context) {
    final facts = <(String label, String value, Key key)>[
      (
        'Version',
        metadata.displayVersion,
        const ValueKey('about-version-value'),
      ),
      if (metadata.formattedBuildDate case final buildDate?)
        ('Built', buildDate, const ValueKey('about-build-date-value')),
      if (metadata.runtimeToolchainLabel case final toolchain?)
        ('SDK', toolchain, const ValueKey('about-toolchain-value')),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'BUILD',
          style: TextStyle(
            color: palette.muted,
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 8),
        for (final (label, value, rowKey) in facts)
          _BuildFactRow(
            label: label,
            value: value,
            valueKey: rowKey,
            palette: palette,
          ),
      ],
    );
  }
}

final class _BuildFactRow extends StatelessWidget {
  final String label;
  final String value;
  final Key valueKey;
  final FtermOverlayPalette palette;

  const _BuildFactRow({
    required this.label,
    required this.value,
    required this.valueKey,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Text(
              label,
              style: TextStyle(color: palette.muted, fontSize: 11),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              key: valueKey,
              style: TextStyle(color: palette.foreground, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

/// Terminal-themed master-detail open-source license browser backed by
/// [AboutViewModel].
final class FtermLicensesOverlay extends StatefulWidget {
  /// Backing workspace coordinator.
  final FtermWorkspaceController workspace;

  /// Resolved overlay colors derived from the active terminal theme.
  final FtermOverlayPalette palette;

  /// Creates the [FtermLicensesOverlay].
  const FtermLicensesOverlay({
    super.key,
    required this.workspace,
    required this.palette,
  });

  @override
  State<FtermLicensesOverlay> createState() => _FtermLicensesOverlayState();
}

final class _FtermLicensesOverlayState extends State<FtermLicensesOverlay> {
  late final TextEditingController _searchCtrl;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController(
      text: widget.workspace.aboutViewModel.filterQuery,
    );
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.workspace.aboutViewModel;
    final p = widget.palette;

    return ListenableBuilder(
      listenable: vm,
      builder: (_, _) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(
                    key: const ValueKey('licenses-back-button'),
                    onPressed: () =>
                        widget.workspace.setOverlay(FtermOverlay.about),
                    icon: Icon(Icons.arrow_back, size: 16, color: p.foreground),
                    tooltip: 'Back to About (Esc)',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 26,
                      height: 26,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      vm.totalPackageCount > 0
                          ? 'Open Source Licenses (${vm.totalPackageCount})'
                          : 'Open Source Licenses',
                      style: TextStyle(
                        color: p.foreground,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('licenses-close-all'),
                    onPressed: () =>
                        widget.workspace.setOverlay(FtermOverlay.none),
                    icon: Icon(Icons.close, size: 16, color: p.muted),
                    tooltip: 'Close',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 26,
                      height: 26,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('licenses-search-field'),
                controller: _searchCtrl,
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 15, color: p.muted),
                  hintText: 'Filter packages or fonts...',
                  hintStyle: TextStyle(color: p.muted, fontSize: 11),
                  border: OutlineInputBorder(
                    borderSide: BorderSide(color: p.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: p.border),
                  ),
                ),
                onChanged: vm.setFilterQuery,
              ),
              const SizedBox(height: 10),
              Expanded(
                child: _LicensesBody(vm: vm, palette: p),
              ),
            ],
          ),
        );
      },
    );
  }
}

final class _LicensesBody extends StatelessWidget {
  final AboutViewModel vm;
  final FtermOverlayPalette palette;

  const _LicensesBody({required this.vm, required this.palette});

  @override
  Widget build(BuildContext context) {
    if (vm.isLoadingLicenses && vm.totalPackageCount == 0) {
      return Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text(
              'Loading license notices...',
              style: TextStyle(color: palette.muted, fontSize: 12),
            ),
          ],
        ),
      );
    }
    if (vm.licenseError case final error?) {
      return Center(
        child: Text(
          'Unable to load licenses: $error',
          style: TextStyle(color: palette.danger, fontSize: 12),
        ),
      );
    }

    final packages = vm.filteredPackages;
    final selected = vm.selectedPackage;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: 196,
          decoration: BoxDecoration(
            color: palette.surfaceAlt,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: palette.border),
          ),
          child: packages.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'No matching packages',
                      style: TextStyle(color: palette.muted, fontSize: 11),
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: packages.length,
                  itemBuilder: (_, index) {
                    final pkg = packages[index];
                    return _LicensePackageTile(
                      package: pkg,
                      isSelected: selected?.packageName == pkg.packageName,
                      palette: palette,
                      onTap: () => vm.selectPackage(pkg.packageName),
                    );
                  },
                ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: palette.surfaceAlt,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: palette.border),
            ),
            child: _LicenseNoticeDetail(package: selected, palette: palette),
          ),
        ),
      ],
    );
  }
}

final class _LicensePackageTile extends StatelessWidget {
  final PackageLicenseSummary package;
  final bool isSelected;
  final FtermOverlayPalette palette;
  final VoidCallback onTap;

  const _LicensePackageTile({
    required this.package,
    required this.isSelected,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: ValueKey('licenses-pkg-${package.packageName}'),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        color: isSelected
            ? palette.accent.withValues(alpha: 0.16)
            : Colors.transparent,
        child: Row(
          children: [
            Expanded(
              child: Text(
                package.packageName,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isSelected ? palette.accent : palette.foreground,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  fontSize: 11,
                ),
              ),
            ),
            if (package.noticeCount > 1)
              Text(
                '${package.noticeCount}',
                style: TextStyle(color: palette.muted, fontSize: 10),
              ),
          ],
        ),
      ),
    );
  }
}

final class _LicenseNoticeDetail extends StatelessWidget {
  final PackageLicenseSummary? package;
  final FtermOverlayPalette palette;

  const _LicenseNoticeDetail({required this.package, required this.palette});

  @override
  Widget build(BuildContext context) {
    final pkg = package;
    if (pkg == null) {
      return Center(
        child: Text(
          'Select a package to read its license notice.',
          style: TextStyle(color: palette.muted, fontSize: 11),
        ),
      );
    }
    return SingleChildScrollView(
      key: ValueKey('licenses-detail-${pkg.packageName}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            pkg.packageName,
            style: TextStyle(
              color: palette.foreground,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < pkg.notices.length; i++) ...[
            if (i > 0) ...[
              const SizedBox(height: 8),
              Divider(height: 1, color: palette.border),
              const SizedBox(height: 8),
            ],
            for (final para in pkg.notices[i].paragraphs)
              _LicenseParagraphText(paragraph: para, palette: palette),
          ],
        ],
      ),
    );
  }
}

final class _LicenseParagraphText extends StatelessWidget {
  final LicenseParagraphItem paragraph;
  final FtermOverlayPalette palette;

  const _LicenseParagraphText({required this.paragraph, required this.palette});

  @override
  Widget build(BuildContext context) {
    final isCentered = paragraph.indent == LicenseParagraph.centeredIndent;
    final leftInset = isCentered ? 0.0 : paragraph.indent.clamp(0, 8) * 14.0;
    return Padding(
      padding: EdgeInsets.only(left: leftInset, bottom: 8),
      child: SelectableText(
        paragraph.text,
        textAlign: isCentered ? TextAlign.center : TextAlign.left,
        style: TextStyle(color: palette.foreground, fontSize: 11, height: 1.4),
      ),
    );
  }
}
