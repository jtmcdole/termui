/// Represents a 24-bit RGB color with 8-bit alpha, packed into a single 32-bit integer.
/// Using a single final int field minimizes memory footprint for each Color instance.
extension type const Color._(int argb) implements int {
  /// Creates an opaque color from red, green, and blue components.
  const Color(int r, int g, int b)
    : argb = (255 << 24) | ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF);

  /// Creates a color with custom alpha.
  const Color.argb(this.argb);

  /// Extract the alpha channel (0-255).
  int get a => (argb >> 24) & 0xFF;

  /// Extract the red channel (0-255).
  int get r => (argb >> 16) & 0xFF;

  /// Extract the green channel (0-255).
  int get g => (argb >> 8) & 0xFF;

  /// Extract the blue channel (0-255).
  int get b => argb & 0xFF;

  /// Returns true if this color is fully transparent (alpha == 0).
  bool get isTransparent => a == 0;

  /// Creates a string that applies this color as a foreground color to [text].
  String foreground(String text) {
    return '\x1b[38;2;$r;$g;${b}m$text\x1b[0m';
  }

  /// Creates a string that applies this color as a background color to [text].
  String background(String text) {
    return '\x1b[48;2;$r;$g;${b}m$text\x1b[0m';
  }

  /// Returns the ANSI escape sequence for setting this color as foreground.
  String get foregroundCode => '\x1b[38;2;$r;$g;${b}m';

  /// Returns the ANSI escape sequence for setting this color as background.
  String get backgroundCode => '\x1b[48;2;$r;$g;${b}m';
}

/// Common standard colors.
abstract final class Colors {
  /// The `red` color from the CharmTone palette.
  static const Color red = Color(255, 0, 0);

  /// The `green` color from the CharmTone palette.
  static const Color green = Color(0, 255, 0);

  /// The `blue` color from the CharmTone palette.
  static const Color blue = Color(0, 0, 255);

  /// The `white` color from the CharmTone palette.
  static const Color white = Color(255, 255, 255);

  /// The `black` color from the CharmTone palette.
  static const Color black = Color(0, 0, 0);

  /// The `orange` color from the CharmTone palette.
  static const Color orange = Color(255, 165, 0);

  /// The `yellow` color from the CharmTone palette.
  static const Color yellow = Color(255, 255, 0);
}

/// The official CharmTone color palette from the Charm/Bubble Tea ecosystem.
abstract final class CharmColors {
  // --- Warm Colors ---
  /// The `cumin` color from the CharmTone palette.
  static const Color cumin = Color(0xBF, 0x97, 0x6F);

  /// The `tang` color from the CharmTone palette.
  static const Color tang = Color(0xFF, 0x98, 0x5A);

  /// The `yam` color from the CharmTone palette.
  static const Color yam = Color(0xFF, 0xB5, 0x87);

  /// The `paprika` color from the CharmTone palette.
  static const Color paprika = Color(0xD3, 0x6C, 0x64);

  /// The `bengal` color from the CharmTone palette.
  static const Color bengal = Color(0xFF, 0x6E, 0x63);

  /// The `uni` color from the CharmTone palette.
  static const Color uni = Color(0xFF, 0x93, 0x7D);

  /// The `sriracha` color from the CharmTone palette.
  static const Color sriracha = Color(0xEB, 0x42, 0x68);

  /// The `coral` color from the CharmTone palette.
  static const Color coral = Color(0xFF, 0x57, 0x7D);

  /// The `salmon` color from the CharmTone palette.
  static const Color salmon = Color(0xFF, 0x7F, 0x90);

  /// The `chili` color from the CharmTone palette.
  static const Color chili = Color(0xE2, 0x30, 0x80);

  /// The `cherry` color from the CharmTone palette.
  static const Color cherry = Color(0xFF, 0x38, 0x8B);

  // --- Other Main Spectrum Colors ---
  /// The `tuna` color from the CharmTone palette.
  static const Color tuna = Color(0xFF, 0x6D, 0xAA);

  /// The `macaron` color from the CharmTone palette.
  static const Color macaron = Color(0xE9, 0x40, 0xB0);

  /// The `pony` color from the CharmTone palette.
  static const Color pony = Color(0xFF, 0x4F, 0xBF);

  /// The `cheeky` color from the CharmTone palette.
  static const Color cheeky = Color(0xFF, 0x79, 0xD0);

  /// The `flamingo` color from the CharmTone palette.
  static const Color flamingo = Color(0xF9, 0x47, 0xE3);

  /// The `urchin` color from the CharmTone palette.
  static const Color urchin = Color(0xC3, 0x37, 0xE0);

  /// The `mochi` color from the CharmTone palette.
  static const Color mochi = Color(0xEB, 0x5D, 0xFF);

  /// The `lilac` color from the CharmTone palette.
  static const Color lilac = Color(0xF3, 0x79, 0xFF);

  /// The `prince` color from the CharmTone palette.
  static const Color prince = Color(0x9C, 0x35, 0xE1);

  /// The `violet` color from the CharmTone palette.
  static const Color violet = Color(0xC2, 0x59, 0xFF);

  /// The `mauve` color from the CharmTone palette.
  static const Color mauve = Color(0xD4, 0x6E, 0xFF);

  /// The `grape` color from the CharmTone palette.
  static const Color grape = Color(0x71, 0x34, 0xDD);

  /// The `plum` color from the CharmTone palette.
  static const Color plum = Color(0x99, 0x53, 0xFF);

  /// The `orchid` color from the CharmTone palette.
  static const Color orchid = Color(0xAD, 0x6E, 0xFF);

  /// The `ox` color from the CharmTone palette.
  static const Color ox = Color(0x33, 0x31, 0xB2);

  /// The `sapphire` color from the CharmTone palette.
  static const Color sapphire = Color(0x49, 0x49, 0xFF);

  /// The `guppy` color from the CharmTone palette.
  static const Color guppy = Color(0x72, 0x72, 0xFF);

  /// The `oceania` color from the CharmTone palette.
  static const Color oceania = Color(0x2B, 0x55, 0xB3);

  /// The `thunder` color from the CharmTone palette.
  static const Color thunder = Color(0x47, 0x76, 0xFF);

  /// The `anchovy` color from the CharmTone palette.
  static const Color anchovy = Color(0x71, 0x9A, 0xFC);

  /// The `damson` color from the CharmTone palette.
  static const Color damson = Color(0x00, 0x7A, 0xB8);

  /// The `malibu` color from the CharmTone palette.
  static const Color malibu = Color(0x00, 0xA4, 0xFF);

  /// The `sardine` color from the CharmTone palette.
  static const Color sardine = Color(0x4F, 0xBE, 0xFE);

  /// The `zinc` color from the CharmTone palette.
  static const Color zinc = Color(0x10, 0xB1, 0xAE);

  /// The `turtle` color from the CharmTone palette.
  static const Color turtle = Color(0x0A, 0xDC, 0xD9);

  /// The `lichen` color from the CharmTone palette.
  static const Color lichen = Color(0x5C, 0xDF, 0xEA);

  /// The `guac` color from the CharmTone palette.
  static const Color guac = Color(0x12, 0xC7, 0x8F);

  /// The `mustard` color from the CharmTone palette.
  static const Color mustard = Color(0xF5, 0xEF, 0x34);

  /// The `citron` color from the CharmTone palette.
  static const Color citron = Color(0xE8, 0xFF, 0x27);

  // --- Neutrals ---
  /// The `pepper` color from the CharmTone palette.
  static const Color pepper = Color(0x20, 0x1F, 0x26);

  /// The `bbq` color from the CharmTone palette.
  static const Color bbq = Color(0x2D, 0x2C, 0x36);

  /// The `char` color from the CharmTone palette.
  static const Color char = Color(0x3A, 0x39, 0x43);

  /// The `iron` color from the CharmTone palette.
  static const Color iron = Color(0x4D, 0x4C, 0x57);

  /// The `oyster` color from the CharmTone palette.
  static const Color oyster = Color(0x60, 0x5F, 0x6B);

  /// The `squid` color from the CharmTone palette.
  static const Color squid = Color(0x85, 0x83, 0x92);

  /// The `steam` color from the CharmTone palette.
  static const Color steam = Color(0xA2, 0xA0, 0xAD);

  /// The `smoke` color from the CharmTone palette.
  static const Color smoke = Color(0xBF, 0xBC, 0xC8);

  /// The `steep` color from the CharmTone palette.
  static const Color steep = Color(0xD6, 0xD3, 0xDC);

  /// The `sash` color from the CharmTone palette.
  static const Color sash = Color(0xEC, 0xEB, 0xF0);

  /// The `salt` color from the CharmTone palette.
  static const Color salt = Color(0xF7, 0xF6, 0xFB);

  /// The `soda` color from the CharmTone palette.
  static const Color soda = Color(0xFB, 0xFB, 0xFB);

  // --- Primary Colors ---
  /// The `charple` color from the CharmTone palette.
  static const Color charple = Color(0x6B, 0x50, 0xFF);

  /// The `dolly` color from the CharmTone palette.
  static const Color dolly = Color(0xFF, 0x60, 0xFF);

  /// The `julep` color from the CharmTone palette.
  static const Color julep = Color(0x00, 0xFF, 0xB2);

  /// The `zest` color from the CharmTone palette.
  static const Color zest = Color(0xE8, 0xFE, 0x96);

  /// The `hazy` color from the CharmTone palette.
  static const Color hazy = Color(0x8B, 0x75, 0xFF);

  /// The `blush` color from the CharmTone palette.
  static const Color blush = Color(0xFF, 0x84, 0xFF);

  /// The `bok` color from the CharmTone palette.
  static const Color bok = Color(0x68, 0xFF, 0xD6);

  /// The `butter` color from the CharmTone palette.
  static const Color butter = Color(0xFF, 0xFA, 0xF1);

  // --- Secondary / Extra Colors ---
  /// The `ice` color from the CharmTone palette.
  static const Color ice = Color(0x00, 0xFF, 0xFC);

  /// The `jelly` color from the CharmTone palette.
  static const Color jelly = Color(0x4A, 0x30, 0xD9);

  /// The `darple` color from the CharmTone palette.
  static const Color darple = Color(0x5B, 0x40, 0xEC);

  /// The `larple` color from the CharmTone palette.
  static const Color larple = Color(0x7B, 0x62, 0xFF);

  // --- Diff Colors ---
  /// The `spinach` color from the CharmTone palette.
  static const Color spinach = Color(0x1C, 0x36, 0x34);

  /// The `gator` color from the CharmTone palette.
  static const Color gator = Color(0x18, 0x46, 0x3D);

  /// The `pickle` color from the CharmTone palette.
  static const Color pickle = Color(0x00, 0xA4, 0x75);

  /// The `toast` color from the CharmTone palette.
  static const Color toast = Color(0x41, 0x21, 0x30);

  /// The `steak` color from the CharmTone palette.
  static const Color steak = Color(0x58, 0x22, 0x38);

  /// The `pom` color from the CharmTone palette.
  static const Color pom = Color(0xAB, 0x24, 0x54);

  // --- Collections & Ramps ---
  /// The `main` collection of colors from the CharmTone palette.
  static const List<Color> main = [
    cumin,
    tang,
    yam,
    paprika,
    bengal,
    uni,
    sriracha,
    coral,
    salmon,
    chili,
    cherry,
    tuna,
    macaron,
    pony,
    cheeky,
    flamingo,
    dolly,
    blush,
    urchin,
    mochi,
    lilac,
    prince,
    violet,
    mauve,
    grape,
    plum,
    orchid,
    jelly,
    charple,
    hazy,
    ox,
    sapphire,
    guppy,
    oceania,
    thunder,
    anchovy,
    damson,
    malibu,
    sardine,
    zinc,
    turtle,
    lichen,
    guac,
    julep,
    bok,
    mustard,
    citron,
    zest,
    butter,
  ];

  /// The `warm` collection of colors from the CharmTone palette.
  static const List<Color> warm = [
    cumin,
    tang,
    yam,
    paprika,
    bengal,
    uni,
    sriracha,
    coral,
    salmon,
    chili,
    cherry,
  ];

  /// The `neutrals` collection of colors from the CharmTone palette.
  static const List<Color> neutrals = [
    pepper,
    bbq,
    char,
    iron,
    oyster,
    squid,
    steam,
    smoke,
    steep,
    sash,
    salt,
    soda,
  ];

  /// The `primary` collection of colors from the CharmTone palette.
  static const List<Color> primary = [
    charple,
    dolly,
    julep,
    zest,
    hazy,
    blush,
    bok,
    butter,
  ];

  /// The `charpleRamp` collection of colors from the CharmTone palette.
  static const List<Color> charpleRamp = [jelly, darple, charple, larple, hazy];

  /// The `additions` collection of colors from the CharmTone palette.
  static const List<Color> additions = [spinach, gator, pickle, julep];

  /// The `deletions` collection of colors from the CharmTone palette.
  static const List<Color> deletions = [toast, steak, pom, cherry];
}

/// Extension on [int] to provide easy access and manipulation of ARGB colors
/// represented as 32-bit integers.
extension ColorIntExtension on int {
  /// Extract the alpha channel (0-255).
  int get a => (this >> 24) & 0xFF;

  /// Extract the red channel (0-255).
  int get r => (this >> 16) & 0xFF;

  /// Extract the green channel (0-255).
  int get g => (this >> 8) & 0xFF;

  /// Extract the blue channel (0-255).
  int get b => this & 0xFF;

  /// Returns true if this color is fully transparent (alpha == 0).
  bool get isTransparent => a == 0;

  /// Returns a new ARGB integer with the updated alpha value (0-255).
  int withAlpha(int a) => (this & 0x00FFFFFF) | ((a & 0xFF) << 24);

  /// Returns a new ARGB integer with the updated red value (0-255).
  int withRed(int r) => (this & 0xFF00FFFF) | ((r & 0xFF) << 16);

  /// Returns a new ARGB integer with the updated green value (0-255).
  int withGreen(int g) => (this & 0xFFFF00FF) | ((g & 0xFF) << 8);

  /// Returns a new ARGB integer with the updated blue value (0-255).
  int withBlue(int b) => (this & 0xFFFFFF00) | (b & 0xFF);
}
