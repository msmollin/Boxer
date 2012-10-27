/*
 Boxer is copyright 2011 Alun Bestor and contributors.
 Boxer is released under the GNU General Public License 2.0. A full copy of this license can be
 found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */

#import "BXEmulatorPrivate.h"
#import "BXEmulatedPrinter.h"
#import "printer_charmaps.h"
#import "BXCoalface.h"


#pragma mark -
#pragma mark Private constants

//Flags for the control register, as set and returned by BXEmulatedPrinter.controlRegister
enum {
    BXEmulatedPrinterControlStrobe      = 1 << 0,   //'Flashed' to indicate that data is waiting to be read.
    BXEmulatedPrinterControlAutoFeed    = 1 << 1,   //Tells the device to handle linebreaking automatically.
    BXEmulatedPrinterControlReset       = 1 << 2,   //Tells the device to initialize/reset.
    
    BXEmulatedPrinterControlSelect      = 1 << 3,   //Tells the device to select. Unsupported.
    BXEmulatedPrinterControlEnableIRQ   = 1 << 4,   //Tells the device to enable interrupts. Unsupported.
    BXEmulatedPrinterControlEnableBiDi  = 1 << 5,   //Tells the device to enable bidirectional communication. Unsupported.
    
    //Bits 6 and 7 are reserved
    
    //Used when reporting the current control register, to mask unsupported bits 5, 6 and 7.
    BXEmulatedPrinterControlMask        = 0xe0,
};

//Flags for the status register, as returned by BXEmulatedPrinter.statusRegister
enum {
    //Bits 0 and 1 are reserved
    
    BXEmulatedPrinterNoInterrupt        = 1 << 2,   //When *unset*, indicates an interrupt has occurred. Unsupported.
    BXEmulatedPrinterStatusNoError      = 1 << 3,   //When *unset*, indicates the device has encountered an error.
    BXEmulatedPrinterStatusSelected     = 1 << 4,   //Indicates the device is online and selected.
    BXEmulatedPrinterStatusPaperEmpty   = 1 << 5,   //Indicates there is no paper remaining.
    BXEmulatedPrinterStatusNoAck        = 1 << 6,   //When *unset*, indicates acknowledgement that data has been read.
    BXEmulatedPrinterStatusReady        = 1 << 7,   //When *unset*, the device is busy and no data should be sent.

    //Used when reporting the current status register, to mask unsupported bits 0, 1, 2.
    BXEmulatedPrinterStatusMask         = 0x07,
};

//Helper macro that returns two adjacent 8-bit parameters from an array, merged into a single 16-bit parameter
#define WIDEPARAM(p, i) (p[i] + (p[i+1] << 8))

//Used to flag extended ESC/P2 and IBM commands so that they can be handled with the same byte-eating logic
#define ESCP2_FLAG 0x200
#define IBM_FLAG 0x800

//Used to flag ESC2 commands that we don't support but whose parameters we still need to eat from the bytestream
#define UNSUPPORTED_ESC2_COMMAND 0x101

#define VERTICAL_TABS_UNDEFINED 255
#define UNIT_SIZE_UNDEFINED -1
#define HMI_UNDEFINED -1


#pragma mark -
#pragma mark Private interface declaration

@interface BXEmulatedPrinter ()

@property (assign, nonatomic) BOOL bold;
@property (assign, nonatomic) BOOL italic;
@property (assign, nonatomic) BOOL doubleStrike;

@property (assign, nonatomic) BOOL superscript;
@property (assign, nonatomic) BOOL subscript;

@property (assign, nonatomic) BOOL proportional;
@property (assign, nonatomic) BOOL condensed;
@property (assign, nonatomic) double letterSpacing;

@property (assign, nonatomic) BOOL doubleWidth;
@property (assign, nonatomic) BOOL doubleHeight;
@property (assign, nonatomic) BOOL doubleWidthForLine;

@property (assign, nonatomic) BOOL underlined;
@property (assign, nonatomic) BOOL linethroughed;
@property (assign, nonatomic) BOOL overscored;
@property (assign, nonatomic) BXEmulatedPrinterLineStyle lineStyle;

@property (assign, nonatomic) BXEmulatedPrinterQuality quality;
@property (assign, nonatomic) BXEmulatedPrinterColor color;
@property (assign, nonatomic) BXEmulatedPrinterTypeface typeFace;

@property (assign, nonatomic) BOOL autoFeed;
@property (assign, nonatomic) double CPI;
@property (readonly, nonatomic) double effectiveCPI;

@property (assign, nonatomic) BOOL multipointEnabled;
@property (assign, nonatomic) double multipointCPI;
@property (assign, nonatomic) double multipointFontSize;

@property (assign, nonatomic) BXEmulatedPrinterCharTable activeCharTable;
@property (readonly, nonatomic) NSUInteger activeCodepage;

@property (retain, nonatomic) NSImage *currentPage;
@property (retain, nonatomic) NSMutableArray *completedPages;
@property (retain, nonatomic) NSMutableDictionary *textAttributes;

#pragma mark -
#pragma mark Helper class methods

//Returns the ASCII->Unicode character mapping to use for the specified codepage.
+ (const uint16_t * const) _charmapForCodepage: (NSUInteger)codepage;

//Returns a CMYK-gamut NSColor suitable for the specified color code.
+ (NSColor *) _colorForColorCode: (BXEmulatedPrinterColor)colorCode;

//Returns a font descriptor object that can be used to identify a suitable font for the specified typeface.
+ (NSFontDescriptor *) _fontDescriptorForEmulatedTypeface: (BXEmulatedPrinterTypeface)typeface
                                                     bold: (BOOL)bold
                                                   italic: (BOOL)italic;

#pragma mark -
#pragma mark Initialization

//Called when the DOS session first communicates the intent to print.
- (void) _prepareForPrinting;

//Called when the DOS session changes parameters for text printing.
- (void) _updateTextAttributes;

//Called when the DOS session formfeeds or the print head goes off the extents of the current page.
- (void) _startNewPageSavingPrevious: (BOOL)savePrevious resetHead: (BOOL)resetHead;

//Called when the DOS session prepares a bitmap drawing context.
- (void) _prepareForBitmapWithDensity: (NSUInteger)density columns: (NSUInteger)numColumns;


#pragma mark -
#pragma mark Character mapping functions

//Switch to the specified codepage for ASCII->Unicode mappings.
- (void) _selectCodepage: (NSUInteger)codepage;

//Switch to the specified international character set using the current codepage.
- (void) _selectInternationalCharset: (BXEmulatedPrinterCharset)charsetID;

//Set the specified chartable entry to point to the specified codepage.
//If this chartable is active, the current ASCII mapping will be updated accordingly.
- (void) _assignCodepage: (NSUInteger)codepage
             toCharTable: (BXEmulatedPrinterCharTable)charTable;


#pragma mark -
#pragma mark Command handling

//Open a context for parsing an ESC/P (or FS) command code.
- (void) _beginESCPCommandWithCode: (uint8_t)commandCode isFSCommand: (BOOL)isFS;

//Add the specified byte as a parameter to the current ESC/P command.
- (void) _parseESCPCommandParameter: (uint8_t)parameter;

//Called after command processing is complete, to close up the command context.
- (void) _endESCPCommand;

@end


#pragma mark -
#pragma mark Implementation

@implementation BXEmulatedPrinter

@synthesize delegate = _delegate;

@synthesize dataRegister = _dataRegister;

@synthesize autoFeed = _autoFeed;

@synthesize bold = _bold;
@synthesize italic = _italic;
@synthesize doubleStrike = _doubleStrike;

@synthesize superscript = _superscript;
@synthesize subscript = _subscript;

@synthesize proportional = _proportional;
@synthesize condensed = _condensed;
@synthesize doubleWidth = _doubleWidth;
@synthesize doubleHeight = _doubleHeight;
@synthesize doubleWidthForLine = _doubleWidthForLine;

@synthesize underlined = _underlined;
@synthesize linethroughed = _linethroughed;
@synthesize overscored = _overscored;
@synthesize lineStyle = _lineStyle;

@synthesize letterSpacing = _letterSpacing;
@synthesize typeFace = _typeFace;
@synthesize color = _color;
@synthesize quality = _quality;

@synthesize multipointEnabled = _multipointEnabled;
@synthesize multipointFontSize = _multipointFontSize;
@synthesize CPI = _charactersPerInch;
@synthesize multipointCPI = _multipointCharactersPerInch;
@synthesize effectiveCPI = _effectiveCharactersPerInch;

@synthesize activeCharTable = _activeCharTable;

@synthesize currentPage = _currentPage;
@synthesize completedPages = _completedPages;
@synthesize textAttributes = _textAttributes;


- (id) init
{
    self = [super init];
    if (self)
    {
        _controlRegister = BXEmulatedPrinterControlReset;
        _initialized = NO;
        self.completedPages = [NSMutableArray arrayWithCapacity: 1];
    }
    return self;
}

- (void) dealloc
{
    self.currentPage = nil;
    self.completedPages = nil;
    self.textAttributes = nil;
    
    [super dealloc];
}


#pragma mark -
#pragma mark Helper class methods

+ (const uint16_t *) _charmapForCodepage: (NSUInteger)codepage
{
	NSUInteger i=0;
    while(charmap[i].codepage != 0)
    {
		if (charmap[i].codepage == codepage)
			return charmap[i].map;
		i++;
	}
    
    //If we get this far, no matching codepage could be found.
    return NULL;
}

+ (NSColor *) _colorForColorCode: (BXEmulatedPrinterColor)colorCode
{
    CGFloat c, y, m, k;
    switch (colorCode)
    {
        case BXEmulatedPrinterColorCyan:
            c=1; y=0; m=0; k=0; break;
            
        case BXEmulatedPrinterColorMagenta:
            c=0; y=0; m=1; k=0; break;
            
        case BXEmulatedPrinterColorYellow:
            c=0; y=1; m=0; k=0; break;
            
        case BXEmulatedPrinterColorRed:
            c=0; y=1; m=1; k=0; break;
            
        case BXEmulatedPrinterColorGreen:
            c=1; y=1; m=0; k=0; break;
            
        case BXEmulatedPrinterColorViolet:
            c=1; y=0; m=1; k=0; break;
        
        case BXEmulatedPrinterColorBlack:
        default:
            c=0; y=0; m=0; k=1; break;
    }
    return [NSColor colorWithDeviceCyan: c magenta: m yellow: y black: k alpha: 1];
}


#pragma mark -
#pragma mark Formatting

- (void) setBold: (BOOL)flag
{
    if (self.bold != flag)
    {
        _bold = flag;
        [self _updateTextAttributes];
    }
}

- (void) setItalic: (BOOL)flag
{
    if (self.italic != flag)
    {
        _italic = flag;
        [self _updateTextAttributes];
    }
}

- (void) setCondensed: (BOOL)flag
{
    if (self.condensed != flag)
    {
        _condensed = flag;
        _horizontalMotionIndex = HMI_UNDEFINED;
        [self _updateTextAttributes];
    }
}

- (void) setSubscript: (BOOL)flag
{
    if (self.subscript != flag)
    {
        _subscript = flag;
        [self _updateTextAttributes];
    }
}

- (void) setSuperscript: (BOOL)flag
{
    if (self.superscript != flag)
    {
        _superscript = flag;
        [self _updateTextAttributes];
    }
}

- (void) setLetterSpacing: (double)spacing
{
    _letterSpacing = spacing;
    _horizontalMotionIndex = HMI_UNDEFINED;
}

- (void) setDoubleWidth: (BOOL)flag
{
    if (self.doubleWidth != flag)
    {
        _doubleWidth = flag;
        _horizontalMotionIndex = HMI_UNDEFINED;
        [self _updateTextAttributes];
    }
}

- (void) setDoubleHeight: (BOOL)flag
{
    if (self.doubleHeight != flag)
    {
        _doubleHeight = flag;
        [self _updateTextAttributes];
    }
}

- (void) setDoubleWidthForLine: (BOOL)flag
{
    if (self.doubleWidthForLine != flag)
    {
        _doubleWidthForLine = flag;
        _horizontalMotionIndex = HMI_UNDEFINED;
        [self _updateTextAttributes];
    }
}

- (void) setColor: (BXEmulatedPrinterColor)color
{
    if (BXEmulatedPrinterColorBlack < 0 || color > BXEmulatedPrinterColorGreen)
        color = BXEmulatedPrinterColorBlack;
    
    _color = color;
}

- (void) setUnderlined: (BOOL)flag
{
    if (self.underlined != flag)
    {
        _underlined = flag;
        [self _updateTextAttributes];
    }
}

- (void) setOverscored: (BOOL)flag
{
    if (self.overscored != flag)
    {
        _overscored = flag;
        [self _updateTextAttributes];
    }
}

- (void) setLinethroughed: (BOOL)flag
{
    if (self.linethroughed != flag)
    {
        _linethroughed = flag;
        [self _updateTextAttributes];
    }
}

- (void) setTypeFace: (BXEmulatedPrinterTypeface)typeFace
{
    switch (typeFace)
    {
        case BXEmulatedPrinterTypefaceRoman:
        case BXEmulatedPrinterTypefaceSansSerif:
        case BXEmulatedPrinterTypefaceCourier:
        case BXEmulatedPrinterTypefacePrestige:
        case BXEmulatedPrinterTypefaceScript:
        case BXEmulatedPrinterTypefaceOCRB:
        case BXEmulatedPrinterTypefaceOCRA:
        case BXEmulatedPrinterTypefaceOrator:
        case BXEmulatedPrinterTypefaceOratorS:
        case BXEmulatedPrinterTypefaceScriptC:
        case BXEmulatedPrinterTypefaceRomanT:
        case BXEmulatedPrinterTypefaceSansSerifH:
        case BXEmulatedPrinterTypefaceSVBusaba:
        case BXEmulatedPrinterTypefaceSVJittra:
            _typeFace = (BXEmulatedPrinterTypeface)typeFace;
            [self _updateTextAttributes];
            break;
        default:
            break;
    }
}

- (void) _updateTextAttributes
{
    NSFontDescriptor *fontDescriptor = [self.class _fontDescriptorForEmulatedTypeface: self.typeFace
                                                                                 bold: self.bold
                                                                               italic: self.italic];
    
    //Work out the effective horizontal and vertical scale we need for the text.
    NSSize fontSize;
	if (self.multipointEnabled)
    {
        _effectiveCharactersPerInch = _multipointCharactersPerInch;
        fontSize = NSMakeSize(_multipointFontSize, _multipointFontSize);
    }
    else
    {
        //Use a base font size of 10.5 points
        fontSize = NSMakeSize(10.5, 10.5);
        _effectiveCharactersPerInch = _charactersPerInch;
        
        if (self.condensed)
        {
            if (self.proportional)
            {
                fontSize.width *= 0.5;
            }
            else if (_charactersPerInch == 10.0)
            {
                _effectiveCharactersPerInch = 17.14;
                fontSize.width *= 10.0 / _effectiveCharactersPerInch;
                fontSize.height *= 10.0 / _charactersPerInch;
            }
            else if (_charactersPerInch == 12.0)
            {
                _effectiveCharactersPerInch = 20.0;
                fontSize.width *= 10.0 / _effectiveCharactersPerInch;
                fontSize.height *= 10.0 / _charactersPerInch;
            }
        }
        else
        {
            fontSize.width *= 10.0 / _effectiveCharactersPerInch;
            fontSize.height *= 10.0 / _charactersPerInch;
        }
        
        if (self.doubleWidth || self.doubleWidthForLine)
        {
            _effectiveCharactersPerInch *= 0.5;
            fontSize.width *= 2.0;
        }
        
        if (self.doubleHeight)
        {
            fontSize.height *= 2.0;
        }
	}
    
    if (self.superscript || self.subscript)
    {
        fontSize.width *= 2.0/3.0;
        fontSize.height *= 2.0/3.0;
        _effectiveCharactersPerInch *= 2.0/3.0;
    }
    
    //If the text needs to be scaled in one direction or another,
    //apply a transform to do this.
    CGFloat aspectRatio = (fontSize.width / fontSize.height);
    if (ABS(aspectRatio - 1) > 0.01)
    {
        NSAffineTransform *transform = [NSAffineTransform transform];
        [transform scaleXBy: aspectRatio yBy: 1];
        
        fontDescriptor = [fontDescriptor fontDescriptorWithMatrix: transform];
    }
    
    NSFont *font = [NSFont fontWithDescriptor: fontDescriptor size: fontSize.height];
    NSColor *color = [self.class _colorForColorCode: self.color];
    
    self.textAttributes = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                           font, NSFontAttributeName,
                           color, NSForegroundColorAttributeName,
                           nil];
}

+ (NSFontDescriptor *) _fontDescriptorForEmulatedTypeface: (BXEmulatedPrinterTypeface)typeface
                                                     bold: (BOOL)bold
                                                   italic: (BOOL)italic
{
    NSFontSymbolicTraits traits = 0;
    if (bold) traits |= NSFontBoldTrait;
    if (italic) traits |= NSFontItalicTrait;
    
    NSString *fontName = nil;
    switch (typeface)
    {
        case BXEmulatedPrinterTypefaceOCRA:
        case BXEmulatedPrinterTypefaceOCRB:
            fontName = @"OCR A Std";
            break;
            
        case BXEmulatedPrinterTypefaceCourier:
            fontName = @"Courier";
            break;
            
        case BXEmulatedPrinterTypefaceScript:
        case BXEmulatedPrinterTypefaceScriptC:
            traits |= NSFontScriptsClass;
            break;
            
        case BXEmulatedPrinterTypefaceSansSerif:
        case BXEmulatedPrinterTypefaceSansSerifH:
            fontName = @"Helvetica";
            traits |= NSFontSansSerifClass;
            
        case BXEmulatedPrinterTypefaceRoman:
        case BXEmulatedPrinterTypefaceRomanT:
        default:
            traits |= NSFontModernSerifsClass;
            fontName = @"Times";
            break;
    }
    
    NSDictionary *traitDict = [NSDictionary dictionaryWithObject: [NSNumber numberWithUnsignedInteger: traits]
                                                          forKey: NSFontSymbolicTrait];
    
    NSMutableDictionary *attribs = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                    traitDict, NSFontTraitsAttribute,
                                    nil];
    
    if (fontName)
        [attribs setObject: fontName forKey: NSFontFamilyAttribute];
    
    return [NSFontDescriptor fontDescriptorWithFontAttributes: attribs];
}


#pragma mark -
#pragma mark Character mapping

- (void) _selectCodepage: (NSUInteger)codepage
{
    const uint16_t *mapToUse = [self.class _charmapForCodepage: codepage];
    
    if (mapToUse == NULL)
    {
        //If we have no matching map for this codepage then fall back on CP437,
        //which we know we have a map for.
        NSLog(@"Unsupported codepage %i. Using CP437 instead.", codepage);
        mapToUse = [self.class _charmapForCodepage: 437];
    }
    
    NSUInteger i;
	for (i=0; i<256; i++)
		_charMap[i] = mapToUse[i];
}

- (void) setActiveCharTable: (BXEmulatedPrinterCharTable)charTable
{
    if (_activeCharTable != charTable)
    {
        _activeCharTable = charTable;
        [self _selectCodepage: self.activeCodepage];
    }
}

- (NSUInteger) activeCodepage
{
    return _charTables[_activeCharTable];
}

- (void) _assignCodepage: (NSUInteger)codepage
             toCharTable: (BXEmulatedPrinterCharTable)charTable
{
    _charTables[charTable] = codepage;
    
    if (charTable == self.activeCharTable)
        [self _selectCodepage: codepage];
}

- (void) _selectInternationalCharset: (BXEmulatedPrinterCharset)charsetID
{
    NSUInteger charsetIndex = charsetID;
    if (charsetIndex == BXEmulatedPrinterCharsetLegal)
        charsetIndex = 14;
    
    if (charsetIndex <= 14)
    {
        const uint16_t *charsetChars = intCharSets[charsetIndex];
        
        //Replace certain codepoints in our ASCII->Unicode mapping table with
        //the characters appropriate for the specified international charset.
        uint8_t charAddresses[12] = { 0x23, 0x24, 0x40, 0x5b, 0x5c, 0x5d, 0x5e, 0x60, 0x7b, 0x7c, 0x7d, 0x7e };
        NSUInteger i;
        for (i=0; i<12; i++)
        {
            _charMap[charAddresses[i]] = charsetChars[i];
        }
    }
}


#pragma mark -
#pragma mark Print operations

- (BOOL) isBusy
{
    return NO;
}

- (BOOL) acknowledge
{
    if (_hasReadData)
    {
        _hasReadData = NO;
        return YES;
    }
    return NO;
}

- (void) _prepareForPrinting
{
    _initialized = YES;
    
    //TODO: derive the default page size from OSX's default printer settings instead.
    _defaultPageSize = NSMakeSize(8.27, 11.69); //A4 in inches
    
    //Dots per inch
    _dpi = NSMakeSize(600, 600);
    
    [self resetHard];
}

- (void) resetHard
{
    _hasReadData = NO;
    [self reset];
}

- (void) reset
{
    _expectingESCCommand = NO;
    _expectingFSCommand = NO;
    [self _endESCPCommand];
    
    _typeFace = BXEmulatedPrinterTypefaceDefault;
    _color = BXEmulatedPrinterColorBlack;
    _headPosition = NSZeroPoint;
    _horizontalMotionIndex = HMI_UNDEFINED;
    
    _pageSize = _defaultPageSize;
    _topMargin = 0.0;
    _leftMargin = 0.0;
    _rightMargin = _defaultPageSize.width;
    _bottomMargin = _defaultPageSize.height;
    
    _lineSpacing = BXEmulatedPrinterLineSpacingDefault;
    _letterSpacing = 0.0;
    _charactersPerInch = BXEmulatedPrinterCPIDefault;
    
    _activeCharTable = BXEmulatedPrinterCharTable1;
    _charTables[BXEmulatedPrinterCharTable0] = 0;
    _charTables[BXEmulatedPrinterCharTable1] = 437;
    _charTables[BXEmulatedPrinterCharTable2] = 437;
    _charTables[BXEmulatedPrinterCharTable3] = 437;
    
    _bold = NO;
    _italic = NO;
    _doubleStrike = NO;
    
    _superscript = NO;
    _subscript = NO;
    
    _doubleWidth = NO;
    _doubleWidthForLine = NO;
    _doubleHeight = NO;
    _proportional = NO;
    _condensed = NO;
    
    _underlined = NO;
    _linethroughed = NO;
    _overscored = NO;
    _lineStyle = BXEmulatedPrinterLineStyleNone;
    
    _densityK = 0;
    _densityL = 1;
    _densityY = 2;
    _densityZ = 3;
    
    _printUpperControlCodes = NO;
    _numDataBytesToIgnore = 0;
    _numDataBytesToPrint = 0;
    
    _unitSize = UNIT_SIZE_UNDEFINED;
    
    _multipointEnabled = NO;
    _multipointFontSize = 0.0;
    _multipointCharactersPerInch = 0.0;
    
    _msbMode = BXEmulatedPrinterMSBDefault;

    //Apply default tab layout: one every 8 characters
    NSUInteger i;
    for (i=0; i<32; i++)
        _horizontalTabPositions[i] = i * 8 * (1 / _charactersPerInch);
    _numHorizontalTabs = 32;
    _numVerticalTabs = VERTICAL_TABS_UNDEFINED;
    
    [self _updateTextAttributes];
    [self _startNewPageSavingPrevious: NO resetHead: NO];
}

- (void) formFeed
{
    //TODO: toggle saving of page based on whether anything has been drawn into the page yet
    [self _startNewPageSavingPrevious: YES resetHead: YES];
    [self finishPrintSession];
}

- (void) _startNewLine
{
    _headPosition.x = _leftMargin;
    _headPosition.y += _lineSpacing;
    
    if (_headPosition.y > _bottomMargin)
        [self _startNewPageSavingPrevious: YES resetHead: NO];
}

- (void) _startNewPageSavingPrevious: (BOOL)savePrevious resetHead: (BOOL)resetHead
{
    if (savePrevious)
        [self.completedPages addObject: self.currentPage];
    
    _headPosition.y = _topMargin;
    if (resetHead)
        _headPosition.x = _leftMargin;
    
    NSSize canvasSize = NSMakeSize(_pageSize.width * _dpi.width,
                                   _pageSize.height * _dpi.height);
    self.currentPage = [[[NSImage alloc] initWithSize: canvasSize] autorelease];
    [self.currentPage setFlipped: YES];
    
    //Fill the page with white to start with
    [self.currentPage lockFocus];
        [[NSColor whiteColor] set];
        NSRectFill(NSMakeRect(0, 0, canvasSize.width, canvasSize.height));
    [self.currentPage unlockFocus];
}

- (void) finishPrintSession
{
    //IMPLEMENT ME
    //This is where we'd do the actual printing.
    [self.completedPages removeAllObjects];
}

- (void) handleDataByte: (uint8_t)byte
{
    if (!_initialized)
        [self _prepareForPrinting];
    
    _hasReadData = YES;
    
    //For some unsupported ESC/P commands, we know ahead of time that we can ignore
    //all of the bytes making up that command.
    if (_numDataBytesToIgnore > 0)
    {
        _numDataBytesToIgnore--;
        return;
    }
        
    //Apply the current most-significant-bit mode to the byte
    switch (_msbMode)
    {
        case BXEmulatedPrinterMSB0:
            byte &= 0x7F;
            break;
        case BXEmulatedPrinterMSB1:
            byte |= 0x80;
            break;
        case BXEmulatedPrinterMSBDefault:
            break;
    }
    
    //Certain control commands can force n subsequent bytes to be treated as characters to print,
    //even when they would otherwise be interpreted as a new command.
    if (_numDataBytesToPrint > 0)
    {
        _numDataBytesToPrint--;
    }
    else
    {
        //Check if we should handle the byte as a control character.
        if ([self _handleControlCharacter: byte]) return;
    }
    
    //If we get this far, we should treat the byte as a regular character
    //and print it with the current text settings.
    [self _printCharacter: byte];
}

- (void) _prepareForBitmapWithDensity: (NSUInteger)density
                              columns: (NSUInteger)numColumns
{
    //IMPLEMENT ME
}

- (void) _printCharacter: (uint8_t)character
{
    //I have no idea, this was just in the original implementation with no explanation given.
    if (character == 0x01)
        character = 0x20;
    
    //Locate the unicode character to print
    unichar codepoint = _charMap[character];
    
    NSString *stringToPrint = [NSString stringWithCharacters: &codepoint length: 1];
    NSSize stringSize = [stringToPrint sizeWithAttributes: self.textAttributes];
    
    NSPoint headPosInPoints = NSMakePoint(_headPosition.x * _dpi.width,
                                          _headPosition.y * _dpi.height);
    
    [self.currentPage lockFocus];
        [stringToPrint drawAtPoint: headPosInPoints
                    withAttributes: self.textAttributes];
    [self.currentPage unlockFocus];
    
    //Advance the head past the string
    CGFloat advance = 0;
    if (self.proportional)
    {
        advance = stringSize.width;
    }
    else if (_horizontalMotionIndex == HMI_UNDEFINED)
    {
        advance = 1 / _effectiveCharactersPerInch;
    }
    else
    {
        advance = _horizontalMotionIndex;
    }
    
    advance += self.letterSpacing;
    _headPosition.x += advance;
    
    //Wrap the line if the next character would go over the right margin.
    //This may also trigger a new page.
	if((_headPosition.x + advance) > _rightMargin)
    {
        [self _startNewLine];
	}
    
    /*
    // Find the glyph for the char to render
	FT_UInt index = FT_Get_Char_Index(curFont, curMap[ch]);
	
	// Load the glyph
	FT_Load_Glyph(curFont, index, FT_LOAD_DEFAULT);
    
	// Render a high-quality bitmap
	FT_Render_Glyph(curFont->glyph, FT_RENDER_MODE_NORMAL);
    
	Bit16u penX = PIXX + curFont->glyph->bitmap_left;
	Bit16u penY = PIXY - curFont->glyph->bitmap_top + curFont->size->metrics.ascender/64;
    
	if (style & STYLE_SUBSCRIPT) penY += curFont->glyph->bitmap.rows / 2;
    
	// Copy bitmap into page
	SDL_LockSurface(page);
    
	blitGlyph(curFont->glyph->bitmap, penX, penY, false);
	blitGlyph(curFont->glyph->bitmap, penX+1, penY, true);
    
	// Doublestrike => Print the glyph a second time one pixel below
	if (style & STYLE_DOUBLESTRIKE) {
		blitGlyph(curFont->glyph->bitmap, penX, penY+1, true);
		blitGlyph(curFont->glyph->bitmap, penX+1, penY+1, true);
	}
    
	// Bold => Print the glyph a second time one pixel to the right
	// or be a bit more bold...
	if (style & STYLE_BOLD) {
		blitGlyph(curFont->glyph->bitmap, penX+1, penY, true);
		blitGlyph(curFont->glyph->bitmap, penX+2, penY, true);
		blitGlyph(curFont->glyph->bitmap, penX+3, penY, true);
	}
	SDL_UnlockSurface(page);
    
	// For line printing
	Bit16u lineStart = PIXX;
    
	// advance the cursor to the right
	Real64 x_advance;
	if (style &	STYLE_PROP)
		x_advance = (Real64)((Real64)(curFont->glyph->advance.x)/(Real64)(dpi*64));
	else {
		if (hmi < 0) x_advance = 1/(Real64)actcpi;
		else x_advance = hmi;
	}
	x_advance += extraIntraSpace;
     curX += x_advance;
     */
    
	// Draw lines if desired
    /*
	if ((score != SCORE_NONE) && (style &
                                  (STYLE_UNDERLINE|STYLE_STRIKETHROUGH|STYLE_OVERSCORE)))
	{
		// Find out where to put the line
		Bit16u lineY = PIXY;
		double height = (curFont->size->metrics.height>>6); // TODO height is fixed point madness...
        
		if (style & STYLE_UNDERLINE) lineY = PIXY + (Bit16u)(height*0.9);
		else if (style & STYLE_STRIKETHROUGH) lineY = PIXY + (Bit16u)(height*0.45);
		else if (style & STYLE_OVERSCORE)
			lineY = PIXY - (((score == SCORE_DOUBLE)||(score == SCORE_DOUBLEBROKEN))?5:0);
        
		drawLine(lineStart, PIXX, lineY, score==SCORE_SINGLEBROKEN || score==SCORE_DOUBLEBROKEN);
        
		// draw second line if needed
		if ((score == SCORE_DOUBLE)||(score == SCORE_DOUBLEBROKEN))
			drawLine(lineStart, PIXX, lineY + 5, score==SCORE_SINGLEBROKEN || score==SCORE_DOUBLEBROKEN);
	}
	// If the next character would go beyond the right margin, line-wrap.
	if((curX + x_advance) > rightMargin) {
		curX = leftMargin;
		curY += lineSpacing;
		if (curY > bottomMargin) newPage(true,false);
	}
     */
}

- (BOOL) _handleControlCharacter: (uint8_t)byte
{
    //If we've been waiting for the control code for an ESC command, parse this as a control code
    if (_expectingESCCommand || _expectingFSCommand)
	{
        [self _beginESCPCommandWithCode: byte isFSCommand: _expectingFSCommand];
        
        return YES;
	}
    
    //If we've been waiting for additional parameters for an ESC command, parse this as a parameter
    else if (_numParamsExpected > 0)
    {
        [self _parseESCPCommandParameter: byte];
        return YES;
    }
    
    //Otherwise, check if this should be treated as a regular control character
	else
    {
        return [self _parseControlCharacter: byte];
    }
}

- (void) _beginESCPCommandWithCode: (uint8_t)code isFSCommand: (BOOL)isFS
{
    _currentESCPCommand = code;
    
    //Flag this as an FS command to make it easier to handle IBM extended commands without branching logic
    if (isFS)
        _currentESCPCommand |= IBM_FLAG;
    
    _expectingESCCommand = NO;
    _expectingFSCommand = NO;
    _numParamsExpected = 0;
    _numParamsRead = 0;
    
    //Work out how many extra bytes we should expect for this command
    switch (_currentESCPCommand)
    {
        case 0x02: // Undocumented
        case 0x0a: // Reverse line feed											(ESC LF)
        case 0x0c: // Return to top of current page								(ESC FF)
        case 0x0e: // Select double-width printing (one line)					(ESC SO)
        case 0x0f: // Select condensed printing									(ESC SI)
        case '#': // Cancel MSB control                                         (ESC #)
        case '0': // Select 1/8-inch line spacing								(ESC 0)
        case '1': // Select 7/60-inch line spacing								(ESC 1)
        case '2': // Select 1/6-inch line spacing								(ESC 2)
        case '4': // Select italic font                                         (ESC 4)
        case '5': // Cancel italic font                                         (ESC 5)
        case '6': // Enable printing of upper control codes                     (ESC 6)
        case '7': // Enable upper control codes                                 (ESC 7)
        case '8': // Disable paper-out detector                                 (ESC 8)
        case '9': // Enable paper-out detector									(ESC 9)
        case '<': // Unidirectional mode (one line)                             (ESC <)
        case '=': // Set MSB to 0												(ESC =)
        case '>': // Set MSB to 1												(ESC >)
        case '@': // Initialize printer                                         (ESC @)
        case 'E': // Select bold font											(ESC E)
        case 'F': // Cancel bold font											(ESC F)
        case 'G': // Select double-strike printing								(ESC G)
        case 'H': // Cancel double-strike printing								(ESC H)
        case 'M': // Select 10.5-point, 12-cpi									(ESC M)
        case 'O': // Cancel bottom margin [conflict]							(ESC O)
        case 'P': // Select 10.5-point, 10-cpi									(ESC P)
        case 'T': // Cancel superscript/subscript printing						(ESC T)
        case '^': // Enable printing of all character codes on next character	(ESC ^)
        case 'g': // Select 10.5-point, 15-cpi									(ESC g)
            
        case IBM_FLAG | '4': // Select italic font								(FS 4)	(= ESC 4)
        case IBM_FLAG | '5': // Cancel italic font								(FS 5)	(= ESC 5)
        case IBM_FLAG | 'F': // Select forward feed mode						(FS F)
        case IBM_FLAG | 'R': // Select reverse feed mode						(FS R)
            _numParamsExpected = 0;
            break;
            
        case 0x19: // Control paper loading/ejecting							(ESC EM)
        case ' ': // Set intercharacter space									(ESC SP)
        case '!': // Master select												(ESC !)
        case '+': // Set n/360-inch line spacing								(ESC +)
        case '-': // Turn underline on/off										(ESC -)
        case '/': // Select vertical tab channel								(ESC /)
        case '3': // Set n/180-inch line spacing								(ESC 3)
        case 'A': // Set n/60-inch line spacing								(ESC A)
        case 'C': // Set page length in lines									(ESC C)
        case 'I': // Select character type and print pitch						(ESC I)
        case 'J': // Advance print position vertically							(ESC J)
        case 'N': // Set bottom margin											(ESC N)
        case 'Q': // Set right margin											(ESC Q)
        case 'R': // Select an international character set						(ESC R)
        case 'S': // Select superscript/subscript printing						(ESC S)
        case 'U': // Turn unidirectional mode on/off							(ESC U)
            //case 0x56: // Repeat data												(ESC V)
        case 'W': // Turn double-width printing on/off							(ESC W)
        case 'a': // Select justification										(ESC a)
        case 'f': // Absolute horizontal tab in columns [conflict]				(ESC f)
        case 'h': // Select double or quadruple size							(ESC h)
        case 'i': // Immediate print											(ESC i)
        case 'j': // Reverse paper feed										(ESC j)
        case 'k': // Select typeface											(ESC k)
        case 'l': // Set left margin											(ESC l)
        case 'p': // Turn proportional mode on/off								(ESC p)
        case 'r': // Select printing color										(ESC r)
        case 's': // Low-speed mode on/off										(ESC s)
        case 't': // Select character table									(ESC t)
        case 'w': // Turn double-height printing on/off						(ESC w)
        case 'x': // Select LQ or draft										(ESC x)
        case '~': // Select/Deselect slash zero								(ESC ~)
            
        case IBM_FLAG | '2': // Select 1/6-inch line spacing					(FS 2)	(= ESC 2)
        case IBM_FLAG | '3': // Set n/360-inch line spacing						(FS 3)	(= ESC +)
        case IBM_FLAG | 'A': // Set n/60-inch line spacing						(FS A)	(= ESC A)
        case IBM_FLAG | 'C':	// Select LQ type style							(FS C)	(= ESC k)
        case IBM_FLAG | 'E': // Select character width							(FS E)
        case IBM_FLAG | 'I': // Select character table							(FS I)	(= ESC t)
        case IBM_FLAG | 'S': // Select High Speed/High Density elite pitch		(FS S)
        case IBM_FLAG | 'V': // Turn double-height printing on/off				(FS V)	(= ESC w)
            _numParamsExpected = 1;
            break;
            
        case '$': // Set absolute horizontal print position                     (ESC $)
        case '?': // Reassign bit-image mode									(ESC ?)
        case 'K': // Select 60-dpi graphics                                     (ESC K)
        case 'L': // Select 120-dpi graphics									(ESC L)
        case 'Y': // Select 120-dpi, double-speed graphics						(ESC Y)
        case 'Z': // Select 240-dpi graphics									(ESC Z)
        case '\\': // Set relative horizontal print position					(ESC \)
        case 'c': // Set horizontal motion index (HMI)	[conflict]				(ESC c)
        case 'e': // Set vertical tab stops every n lines						(ESC e)
        case IBM_FLAG | 'Z': // Print 24-bit hex-density graphics				(FS Z)
            _numParamsExpected = 2;
            break;
            
        case '*': // Select bit image											(ESC *)
        case 'X': // Select font by pitch and point [conflict]					(ESC X)
            _numParamsExpected = 3;
            break;
            
        case '[': // Select character height, width, line spacing
            _numParamsExpected = 7;
            break;
            
        case 'b': // Set vertical tabs in VFU channels							(ESC b)
        case 'B': // Set vertical tabs											(ESC B)
            _numParamsExpected = UINT_MAX;
            _numVerticalTabs = 0;
            break;
            
        case 'D': // Set horizontal tabs										(ESC D)
            _numParamsExpected = UINT_MAX;
            _numHorizontalTabs = 0;
            break;
            
        case '%': // Select user-defined set									(ESC %)
        case '&': // Define user-defined characters                             (ESC &)
        case ':': // Copy ROM to RAM											(ESC :)
            NSLog(@"PRINTER: User-defined characters not supported.");
            break;
            
        case '(': // Extended ESCP/2 two-byte sequence
            _numParamsExpected = 1;
            break;
            
        default:
            NSLog(@"PRINTER: Unknown command %@ (%02Xh) %c, unable to skip parameters.",
                  (_currentESCPCommand & IBM_FLAG) ? @"FS" : @"ESC", _currentESCPCommand, _currentESCPCommand);
            
            _numParamsExpected = 0;
            _currentESCPCommand = 0;
            break;
    }
    
    //If we don't need any parameters for this command, execute it straight away
    if (_numParamsExpected == 0)
        [self _executeESCCommand: _currentESCPCommand parameters: NULL];
}

- (void) _parseESCPCommandParameter: (uint8_t)param
{
    //Depending on the current command, we may treat this parameter as the second part of the command's control code;
    //or as one in an arbitrary stream of parameters; or as a regular parameter. 
    
    //Complete a two-byte ESCP2 command sequence.
	if (_currentESCPCommand == '(')
	{
		_currentESCPCommand = ESCP2_FLAG | param;
        
		switch (param)
		{
            //case 'B': // Bar code setup and print (ESC (B)
            case '^': // Print data as characters (ESC (^)
                _numParamsExpected = 2;
                break;
            case 'U': // Set unit (ESC (U)
                _numParamsExpected = 3;
                break;
            case 'C': // Set page length in defined unit (ESC (C)
            case 'V': // Set absolute vertical print position (ESC (V)
            case 'v': // Set relative vertical print position (ESC (v)
                _numParamsExpected = 4;
                break;
            case 't': // Assign character table (ESC (t)
            case '-': // Select line/score (ESC (-)
                _numParamsExpected = 5;
                break;
            case 'c': // Set page format (ESC (c)
                _numParamsExpected = 6;
                break;
            default:
                //ESC ( commands are always followed by a "number of parameters" double-byte parameter.
                //To skip unsupported commands, we need to read at least the next two bytes to determine
                //how many more bytes to skip.
				NSLog(@"PRINTER: Skipping unsupported command ESC ( %c (%02X).", _currentESCPCommand, _currentESCPCommand);
                _numParamsExpected = 2;
                _currentESCPCommand = UNSUPPORTED_ESC2_COMMAND;
                break;
		}
	}
    
    //The ESC B and ESC D commands accept arbitrary-length streams of bytes terminated by a NUL sentinel. 
	//Collect a stream of horizontal tab positions.
	else if (_currentESCPCommand == 'D')
	{
        //Horizontal tab positions are specified as number of characters from left margin; convert this to a width in inches.
        double tabPos = param * (1 / (double)_charactersPerInch);
        
        //Once we get a null sentinel or a tab position that's lower than the previous position,
        //treat that as the end of the command.
        if (param == '\0' || (_numHorizontalTabs > 0 && _horizontalTabPositions[_numHorizontalTabs - 1] > tabPos))
        {
            [self _endESCPCommand];
        }
		else if (_numHorizontalTabs < BXEmulatedPrinterMaxHorizontalTabs)
        {
            _horizontalTabPositions[_numHorizontalTabs++] = tabPos;
        }
	}
    
	//Collect a stream of vertical tab positions.
	else if (_currentESCPCommand == 'B')
    {
        //Vertical tab positions are specified as number of lines from top margin; convert this to a height in inches.
        double tabPos = param * _lineSpacing;
        
        //Once we get a null sentinel or a tab position that's lower than the previous position,
        //treat that as the end of the command.
		if (param == '\0' || (_numVerticalTabs > 0 && _verticalTabPositions[_numVerticalTabs - 1] > tabPos))
        {
            [self _endESCPCommand];
        }
		else if (_numVerticalTabs < BXEmulatedPrinterMaxVerticalTabs)
        {
            _verticalTabPositions[_numVerticalTabs++] = tabPos;
        }
	}
    
    //The deprecated "ESC b" command allowed the client to specify sets of vertical tabs for specific VFU channels.
    //This is unsupported, so we ignore the VFU channel specified and handle the following bytes as if they were part
    //of a regular "ESC B" set-vertical-tabs command, as above.
	else if (_currentESCPCommand == 'b')
    {
		_currentESCPCommand = 'B';
	}
    
    //If we got this far, then this was a parameter to a known non-variadic command.
    //Add this byte to the regular parameter list.
    else
    {
        _commandParams[_numParamsRead++] = param;

        //If we've received enough parameters now, execute the command immediately.
        if (_numParamsRead >= _numParamsExpected)
            [self _executeESCCommand: _currentESCPCommand parameters: _commandParams];
	}
}

- (void) _executeESCCommand: (uint16_t)command parameters: (uint8_t *)params
{
    switch (command)
    {
        case 0x02: // Undocumented
            // Ignore
            break;
            
        case 0x0e: // Select double-width printing (one line) (ESC SO)
            if (!self.multipointEnabled)
            {
                self.doubleWidthForLine = YES;
            }
            break;
            
        case 0x0f: // Select condensed printing (ESC SI)
            if (!self.multipointEnabled && self.CPI != 15.0)
            {
                self.condensed = YES;
            }
            break;
            
        case 0x19: // Control paper loading/ejecting (ESC EM)
            // We are not really loading paper, so most commands can be ignored
            if (params[0] == 'R')
                [self _startNewPageSavingPrevious: YES resetHead: NO];
            //newPage(true,false); // TODO resetx?
            break;
            
        case ' ': // Set intercharacter space (ESC SP)
            if (!self.multipointEnabled)
            {
                double spacingFactor = (self.quality == BXEmulatedPrinterQualityDraft) ? 120 : 180;
                self.letterSpacing = params[0] / spacingFactor;
            }
            break;
            
        case '!': // Master select (ESC !)
        {
            _charactersPerInch = (params[0] & (1 << 0)) ? 12 : 10;
            
            self.proportional    = (params[0] & (1 << 1));
            self.condensed       = (params[0] & (1 << 2));
            self.bold            = (params[0] & (1 << 3));
            self.doubleStrike    = (params[0] & (1 << 4));
            self.doubleWidth     = (params[0] & (1 << 5));
            self.italic          = (params[0] & (1 << 6));
            
            if (params[0] & (1 << 7))
            {
                self.underlined = YES;
                self.lineStyle = BXEmulatedPrinterLineStyleSingle;
            }
            else
            {
                self.underlined = NO;
            }
            
            _horizontalMotionIndex = HMI_UNDEFINED;
            _multipointEnabled = NO;
            [self _updateTextAttributes];
        }
            break;
            
        case '#': // Cancel MSB control (ESC #)
            _msbMode = BXEmulatedPrinterMSBDefault;
            break;
            
        case '$': // Set absolute horizontal print position (ESC $)
        {
            //The position is a two-byte parameter
            uint16_t position = WIDEPARAM(params, 0);
            
            double effectiveUnitSize = _unitSize;
            if (effectiveUnitSize == UNIT_SIZE_UNDEFINED)
                effectiveUnitSize = 60.0;
            
            CGFloat newX = _leftMargin + (position / effectiveUnitSize);
            if (newX <= _rightMargin)
                _headPosition.x = newX;
        }
            break;
            
        case IBM_FLAG+'Z': // Print 24-bit hex-density graphics (FS Z)
        {
            uint16_t columns = WIDEPARAM(params, 0);
            [self _prepareForBitmapWithDensity: 40 columns: columns];
        }
            break;
            
        case '*': // Select bit image (ESC *)
        {
            uint16_t density = params[0];
            uint16_t columns = WIDEPARAM(params, 1);
            [self _prepareForBitmapWithDensity: density columns: columns];
        }
            break;
            
        case '+': // Set n/360-inch line spacing (ESC +)
        case IBM_FLAG+'3': // Set n/360-inch line spacing (FS 3)
            _lineSpacing = params[0] / 360.0;
            break;
            
        case '-': // Turn underline on/off (ESC -)
            switch (params[0])
        {
            case '0':
            case 0:
                self.underlined = NO;
                break;
            case '1':
            case 1:
                self.underlined = YES;
                self.lineStyle = BXEmulatedPrinterLineStyleSingle;
                break;
        }
            break;
            
        case '/': // Select vertical tab channel (ESC /)
            // Ignore
            break;
            
        case '0': // Select 1/8-inch line spacing (ESC 0)
            _lineSpacing = 1 / 8.0;
            break;
            
        case '2': // Select 1/6-inch line spacing (ESC 2)
            _lineSpacing = 1 / 6.0;
            break;
            
        case '3': // Set n/180-inch line spacing (ESC 3)
            _lineSpacing = params[0] / 180.0;
            break;
            
        case '4': // Select italic font (ESC 4)
            self.italic = YES;
            break;
            
        case '5': // Cancel italic font (ESC 5)
            self.italic = NO;
            break;
            
        case '6': // Enable printing of upper control codes (ESC 6)
            _printUpperControlCodes = YES;
            break;
            
        case '7': // Enable upper control codes (ESC 7)
            _printUpperControlCodes = NO;
            break;
            
        case '<': // Unidirectional mode (one line) (ESC <)
            // We don't have a print head, so just ignore this
            break;
            
        case '=': // Set MSB to 0 (ESC =)
            _msbMode = BXEmulatedPrinterMSB0;
            break;
            
        case '>': // Set MSB to 1 (ESC >)
            _msbMode = BXEmulatedPrinterMSB1;
            break;
            
        case '?': // Reassign bit-image mode (ESC ?)
            switch(params[0])
            {
                case 'K':
                    _densityK = params[1]; break;
                case 'L':
                    _densityL = params[1]; break;
                case 'Y':
                    _densityY = params[1]; break;
                case 'Z':
                    _densityZ = params[1]; break;
            }
            break;
            
        case '@': // Initialize printer (ESC @)
            [self reset];
            break;
            
        case 'A': // Set n/60-inch line spacing
        case IBM_FLAG+'A':
            _lineSpacing = params[0] / 60.0;
            break;
            
        case 'C': // Set page length in lines (ESC C)
            //If the first parameter was specified, set the page length in lines
            if (params[0] > 0)
            {
                _pageSize.height = _bottomMargin = (params[0] * _lineSpacing);
                break;
            }
            //Otherwise if the second parameter was specified, treat that as the page length in inches
            else if (_numParamsRead == 2)
            {
                _pageSize.height = params[1];
                _bottomMargin = _pageSize.height;
                _topMargin = 0.0;
                break;
            }
            //Otherwise, flag that we're waiting for one more parameter and stop command parsing early
            //(without ending the command context.)
            else
            {
                _numParamsExpected = 2;
                return;
            }
            
        case 'E': // Select bold font (ESC E)
            self.bold = YES;
            break;
            
        case 'F': // Cancel bold font (ESC F)
            self.bold = NO;
            break;
            
        case 'G': // Select double-strike printing (ESC G)
            self.doubleStrike = YES;
            break;
            
        case 'H': // Cancel double-strike printing (ESC H)
            self.doubleStrike = NO;
            break;
            
        case 'J': // Advance print position vertically (ESC J n)
        {
            _headPosition.y += (params[0] / 180.0);
            
            if (_headPosition.y > _bottomMargin)
                [self _startNewPageSavingPrevious: YES resetHead: NO];
        }
            break;
            
        case 'K': // Select 60-dpi graphics (ESC K)
        {
            uint16_t columns = WIDEPARAM(params, 0);
            [self _prepareForBitmapWithDensity: _densityK columns: columns];
        }
            break;
            
        case 'L': // Select 120-dpi graphics (ESC L)
        {
            uint16_t columns = WIDEPARAM(params, 0);
            [self _prepareForBitmapWithDensity: _densityL columns: columns];
        }
            break;
            
        case 'M': // Select 10.5-point, 12-cpi (ESC M)
            _charactersPerInch = 12;
            _horizontalMotionIndex = HMI_UNDEFINED;
            _multipointEnabled = NO;
            [self _updateTextAttributes];
            break;
            
        case 'N': // Set bottom margin (ESC N)
            _topMargin = 0.0;
            _bottomMargin = params[0] * _lineSpacing;
            break;
            
        case 'O': // Cancel bottom (and top) margin
            _topMargin = 0.0;
            _bottomMargin = _pageSize.height;
            break;
            
        case 'P': // Select 10.5-point, 10-cpi (ESC P)
            _charactersPerInch = 10;
            _horizontalMotionIndex = HMI_UNDEFINED;
            _multipointEnabled = NO;
            [self _updateTextAttributes];
            break;
            
        case 'Q': // Set right margin
            _rightMargin = (params[0] - 1) / _charactersPerInch;
            break;
            
        case 'R': // Select an international character set (ESC R)
            [self _selectInternationalCharset: (BXEmulatedPrinterCharset)params[0]];
            break;
            
        case 'S': // Select superscript/subscript printing (ESC S)
            switch (params[0])
        {
            case '0':
            case 0:
                self.subscript = YES;
                break;
            case '1':
            case 1:
                self.superscript = YES;
                break;
        }
            break;
            
        case 'T': // Cancel superscript/subscript printing (ESC T)
            self.subscript = self.superscript = NO;
            break;
            
        case 'U': // Turn unidirectional mode on/off (ESC U)
            // We don't have a print head, so just ignore this
            break;
            
        case 'W': // Turn double-width printing on/off (ESC W)
            if (!_multipointEnabled)
            {
                self.doubleWidth = (params[0] == '1' || params[0] == 1);
                self.doubleWidthForLine = NO;
            }
            break;
        case 'X': // Select font by pitch and point (ESC X)
        {
            _multipointEnabled = YES;
            
            //Copy currently non-multipoint CPI if no value was set so far
            if (_multipointCharactersPerInch == 0)
                _multipointCharactersPerInch = _charactersPerInch;
            
            double cpi = params[0];
            double fontSize = WIDEPARAM(params, 1);
            
            if (cpi == 1) // Proportional spacing
            {
                self.proportional = YES;
            }
            else if (cpi >= 5)
            {
                _multipointCharactersPerInch = 360.0 / cpi;
            }
            
            //Font size is specified as a double-byte parameter
            if (fontSize > 0) // Set points
                _multipointFontSize = fontSize / 2.0;
            //Fall back on a default point size of 10.5
            else if (_multipointFontSize == 0)
                _multipointFontSize = 10.5;
            
            [self _updateTextAttributes];
        }
            break;
            
        case 'Y': // Select 120-dpi, double-speed graphics (ESC Y)
        {
            uint16_t columns = WIDEPARAM(params, 0);
            [self _prepareForBitmapWithDensity: _densityY columns: columns];
        }
            break;
            
        case 'Z': // Select 240-dpi graphics (ESC Z)
        {
            uint16_t columns = WIDEPARAM(params, 0);
            [self _prepareForBitmapWithDensity: _densityZ columns: columns];
        }
            break;
            
        case '\\': // Set relative horizontal print position (ESC \)
        {
            //Note that this value is signed, allowing negative offsets
            int16_t offset = WIDEPARAM(params, 0);
            
            double effectiveUnitSize = _unitSize;
            if (effectiveUnitSize == UNIT_SIZE_UNDEFINED)
                effectiveUnitSize = (self.quality == BXEmulatedPrinterQualityDraft) ? 120.0 : 180.0;
            
            _headPosition.x += offset / effectiveUnitSize;
        }
            break;
        case 'a': // Select justification (ESC a)
            // Ignore
            break;
            
        case 'c': // Set horizontal motion index (HMI) (ESC c)
        {
            self.letterSpacing = 0;
            _horizontalMotionIndex = WIDEPARAM(params, 0) / 360.0;
        }
            break;
            
        case 'g': // Select 10.5-point, 15-cpi (ESC g)
            _charactersPerInch = 15;
            _horizontalMotionIndex = HMI_UNDEFINED;
            _multipointEnabled = NO;
            [self _updateTextAttributes];
            break;
            
        case IBM_FLAG+'F': // Select forward feed mode (FS F) - set reverse not implemented yet
            if (_lineSpacing < 0) _lineSpacing *= -1;
            break;
            
        case 'j': // Reverse paper feed (ESC j)
        {
            double reverse = WIDEPARAM(params, 0) / 216.0;
            //IMPLEMENTATION NOTE: the original implementation used to compare against
            //left margin, which was almost certainly a copypaste mistake.
            _headPosition.y = MAX(_headPosition.y - reverse, _topMargin);
            break;
        }
            
        case 'k': // Select typeface (ESC k)
            self.typeFace = (BXEmulatedPrinterTypeface)params[0];
            break;
            
        case 'l': // Set left margin (ESC l)
            _leftMargin = (params[0] - 1) / _charactersPerInch;
            if (_headPosition.x < _leftMargin)
                _headPosition.x = _leftMargin;
            break;
            
        case 'p': // Turn proportional mode on/off (ESC p)
            switch (params[0])
        {
            case '0':
            case 0:
                self.proportional = NO;
                break;
            case '1':
            case 1:
                self.proportional = YES;
                self.quality = BXEmulatedPrinterQualityLQ;
                break;
        }
            self.multipointEnabled = NO;
            break;
            
        case 'r': // Select printing color (ESC r)
            self.color = (BXEmulatedPrinterColor)params[0];
            break;
            
        case 's': // Select low-speed mode (ESC s)
            // Ignore
            break;
            
        case 't': // Select character table (ESC t)
        case IBM_FLAG+'I': // Select character table (FS I)
            switch (params[0])
            {
                case 0:
                case '0':
                    self.activeCharTable = BXEmulatedPrinterCharTable0;
                    break;
                case 1:
                case '1':
                    self.activeCharTable = BXEmulatedPrinterCharTable1;
                    break;
                case 2:
                case '2':
                    self.activeCharTable = BXEmulatedPrinterCharTable2;
                    break;
                case 3:
                case '3':
                    self.activeCharTable = BXEmulatedPrinterCharTable3;
                    break;
            }
            //CHECKME: is this necessary?
            [self _updateTextAttributes];
            break;
            
        case 'w': // Turn double-height printing on/off (ESC w)
            if (!_multipointEnabled)
            {
                self.doubleHeight = (params[0] == '1' || params[0] == 1);
            }
            break;
            
        case 'x': // Select LQ or draft (ESC x)
            switch (params[0])
            {
                case 0:
                case '0':
                    self.quality = BXEmulatedPrinterQualityDraft;
                    self.condensed = YES;
                    break;
                case 1:
                case '1':
                    self.quality = BXEmulatedPrinterQualityLQ;
                    self.condensed = NO;
                    break;
            }
            break;
            
        case ESCP2_FLAG+'t': // Assign character table (ESC (t)
        {
            BXEmulatedPrinterCharTable charTable = (BXEmulatedPrinterCharTable)params[2];
            uint8_t codepageIndex = params[3];
            if (charTable < 4 && codepageIndex < 16)
            {
                [self _assignCodepage: codepages[codepageIndex]
                          toCharTable: charTable];
            }
        }
            break;
            
        case ESCP2_FLAG+'-': // Select line/score (ESC (-)
            self.lineStyle = (BXEmulatedPrinterLineStyle)params[4];
            
            if (self.lineStyle == BXEmulatedPrinterLineStyleNone)
            {
                self.underlined = self.linethroughed = self.overscored = NO;
            }
            else
            {
                if (params[3] == 1)
                    self.underlined = YES;
                else if (params[3] == 2)
                    self.linethroughed = YES;
                else if (params[3] == 3)
                    self.overscored = YES;
            }
            break;
            
        case ESCP2_FLAG+'C': // Set page height in defined unit (ESC (C)
            if (params[0] != 0 && _unitSize > 0)
            {
                _pageSize.height = _bottomMargin = WIDEPARAM(params, 2) * _unitSize;
                _topMargin = 0.0;
            }
            break;
            
        case ESCP2_FLAG+'U': // Set unit (ESC (U)
            _unitSize = params[2] / 3600.0;
            break;
            
        case ESCP2_FLAG+'V': // Set absolute vertical print position (ESC (V)
        {
            double effectiveUnitSize = _unitSize;
            if (effectiveUnitSize == UNIT_SIZE_UNDEFINED)
                effectiveUnitSize = 360.0;
            
            int16_t offset = WIDEPARAM(params, 2);
            CGFloat newPos = _topMargin + (offset * effectiveUnitSize);
            
            if (newPos > _bottomMargin)
                [self _startNewPageSavingPrevious: YES resetHead: NO];
            else
                _headPosition.y = newPos;
        }
            break;
            
        case ESCP2_FLAG+'^': // Print following data as literal characters (ESC (^)
            _numDataBytesToPrint = WIDEPARAM(params, 0);
            break;
            
        case ESCP2_FLAG+'c': // Set page format (ESC (c)
            if (_unitSize > 0)
            {
                double newTop = WIDEPARAM(params, 2) * _unitSize;
                double newBottom = WIDEPARAM(params, 4) * _unitSize;
                if (newTop < newBottom)
                {
                    if (newTop < _pageSize.height)
                        _topMargin = newTop;
                    
                    if (newBottom < _pageSize.height)
                        _bottomMargin = newBottom;
                        
                    if (_headPosition.x < _topMargin)
                        _headPosition.x = _topMargin;
                }
            }
            break;
            
        case ESCP2_FLAG + 'v': // Set relative vertical print position (ESC (v)
        {
            Real64 effectiveUnitSize = _unitSize;
            if (effectiveUnitSize == UNIT_SIZE_UNDEFINED)
                effectiveUnitSize = 360.0;
            
            int16_t offset = WIDEPARAM(params, 2);
            Real64 newPos = _headPosition.y + (offset * effectiveUnitSize);
            if (newPos > _topMargin)
            {
                _headPosition.y = newPos;
                if (_headPosition.y > _bottomMargin)
                    [self _startNewPageSavingPrevious: YES resetHead: NO];
            }
        }
            break;

        case UNSUPPORTED_ESC2_COMMAND: // Skip unsupported ESC ( command but eat its parameters anyway
            _numDataBytesToIgnore = WIDEPARAM(params, 0);
            break;
            
        default:
            if (command & ESCP2_FLAG)
                NSLog(@"PRINTER: Skipped unsupported command ESC ( %c (%02X)",
                      command & ~ESCP2_FLAG,
                      command & ~ESCP2_FLAG);
            else
                NSLog(@"PRINTER: Skipped unsupported command ESC %c (%02X)", command, command);
    }
    
    [self _endESCPCommand];
}

- (void) _endESCPCommand
{
    _currentESCPCommand = 0;
    _numParamsExpected = 0;
    _numParamsRead = 0;
}

- (BOOL) _parseControlCharacter: (uint8_t)character
{
    switch (character)
	{
        case 0x00:  // NUL is ignored by the printer
            return YES;
            
        case '\a':  // Beeper (BEL)
            // BEEEP!
            return YES;
            
        case '\b':	// Backspace (BS)
		{
			double newX;
			if (_horizontalMotionIndex > 0)
				newX = _headPosition.x - _horizontalMotionIndex;
            else
                newX = _headPosition.x - (1 / _effectiveCharactersPerInch);
            
			if (newX >= _leftMargin)
				_headPosition.x = newX;
		}
            return YES;
            
        case '\t':	// Tab horizontally (HT)
		{
			// Find tab right to current pos
			double chosenTabPos = -1;
            NSUInteger i;
			for (i=0; i < _numHorizontalTabs; i++)
            {
                double tabPos = _horizontalTabPositions[i];
				if (tabPos > _headPosition.x)
                {
                    chosenTabPos = tabPos;
                    //IMPLEMENTATION NOTE: original implementation didn't break so would have ended up
                    //tabbing to the final tab offset. This was presumably a mistake.
                    break;
                }
            }
            
			if (chosenTabPos >= 0 && chosenTabPos < _rightMargin)
				_headPosition.x = chosenTabPos;
		}
            return YES;
            
        case '\v':	// Tab vertically (VT)
            if (_numVerticalTabs == 0) // All tabs cancelled => Act like CR
            {
                _headPosition.x = _leftMargin;
            }
            else if (_numVerticalTabs == VERTICAL_TABS_UNDEFINED) // No tabs set since reset => Act like LF
            {
                [self _startNewLine];
            }
            else
            {
                // Find tab below current pos
                double chosenTabPos = -1;
                NSUInteger i;
                for (i=0; i < _numVerticalTabs; i++)
                {
                    double tabPos = _verticalTabPositions[i];
                    if (tabPos > _headPosition.y)
                    {
                        chosenTabPos = tabPos;
                        //IMPLEMENTATION NOTE: original implementation didn't break so would have ended up
                        //tabbing to the final tab offset. This was presumably a mistake.
                        break;
                    }
                }
                
                // Nothing found => Act like FF
                if (chosenTabPos > _bottomMargin || chosenTabPos == -1)
                    [self _startNewPageSavingPrevious: YES resetHead: NO];
                else
                    _headPosition.y = chosenTabPos;
            }
            
            //Now that we're on a new line, terminate double-width mode
            self.doubleWidthForLine = NO;
            return YES;
            
        case '\f':		// Form feed (FF)
            self.doubleWidthForLine = NO;
            [self _startNewPageSavingPrevious: YES resetHead: NO];
            return YES;
            
        case '\r':		// Carriage Return (CR)
            _headPosition.x = _leftMargin;
            if (!self.autoFeed)
                return YES;
            //If autoFeed is enabled, we drop down into the next case to automatically add a line feed
            
        case '\n':		// Line feed
            self.doubleWidthForLine = NO;
            
            [self _startNewLine];
            return YES;
            
        case 0x0e:		//Select double-width printing (one line) (SO)
            if (!_multipointEnabled)
            {
                self.doubleWidthForLine = YES;
            }
            return YES;
            
        case 0x0f:		// Select condensed printing (SI)
            if (!_multipointEnabled && _charactersPerInch != 15.0)
            {
                self.condensed = YES;
            }
            return YES;
            
        case 0x11:		// Select printer (DC1)
            // Ignore
            return YES;
            
        case 0x12:		// Cancel condensed printing (DC2)
            self.condensed = NO;
            return YES;
            
        case 0x13:		// Deselect printer (DC3)
            // Ignore
            return YES;
            
        case 0x14:		// Cancel double-width printing (one line) (DC4)
            self.doubleWidthForLine = NO;
            return YES;
            
        case 0x18:		// Cancel line (CAN)
            return YES;
            
        case 0x1b:		// ESC
            _expectingESCCommand = YES;
            return YES;
            
        case 0x1c:		// FS (IBM commands)
            _expectingFSCommand = YES;
            return YES;
            
        default:
            return NO;
	}
}


#pragma mark -
#pragma mark Registers

- (uint8_t) statusRegister
{
    //Always report that we're selected and have no errors.
    uint8_t status = BXEmulatedPrinterStatusMask | BXEmulatedPrinterStatusNoError | BXEmulatedPrinterStatusSelected;
    
    // Return standard: No error, printer online, no ack and not busy
    if (_initialized)
    {
        if (!self.isBusy)
            status |= BXEmulatedPrinterStatusReady;

        if (![self acknowledge])
            status |= BXEmulatedPrinterStatusNoAck;
    }
    else
    {
        status |= BXEmulatedPrinterStatusReady | BXEmulatedPrinterStatusNoAck;
    }
    return status;
}

- (void) setControlRegister: (uint8_t)controlFlags
{
    BOOL resetWasOn = (_controlRegister & BXEmulatedPrinterControlReset) == BXEmulatedPrinterControlReset;
    BOOL resetIsOn  = (controlFlags & BXEmulatedPrinterControlReset) == BXEmulatedPrinterControlReset;
	if (_initialized && resetIsOn && !resetWasOn)
        [self resetHard];
    
	//When the strobe signal flicks on then off, read the next byte from the data register
    //and print it.
    BOOL strobeWasOn = (_controlRegister & BXEmulatedPrinterControlStrobe);
    BOOL strobeIsOn = (controlFlags & BXEmulatedPrinterControlStrobe);
	if (strobeWasOn && !strobeIsOn)
    {
        [self handleDataByte: self.dataRegister];
	}
    
    //CHECKME: should we toggle the auto-linefeed behaviour *before* processing the data?
	if (_initialized)
    {
        self.autoFeed = (controlFlags & BXEmulatedPrinterControlAutoFeed) == BXEmulatedPrinterControlAutoFeed;
    }
    
	_controlRegister = controlFlags;
    
}

- (uint8_t) controlRegister
{
    uint8_t flags = BXEmulatedPrinterControlMask | _controlRegister;
    
    if (_initialized)
    {
        if (self.autoFeed) flags |= BXEmulatedPrinterControlAutoFeed;
        else flags &= ~BXEmulatedPrinterControlAutoFeed;
    }
    return flags;
}

@end