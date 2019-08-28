// -*- mode: ObjC -*-

/*************************************************
  Copyright 2016-2018 PreEmptive Solutions, LLC
  See LICENSE.txt for licensing information
*************************************************/
  
//  This file is part of class-dump, a utility for examining the Objective-C segment of Mach-O files.
//  Copyright (C) 1997-1998, 2000-2001, 2004-2015 Steve Nygard.

#include <getopt.h>
#include <libgen.h>

#import "CDClassDump.h"
#import "CDFindMethodVisitor.h"
#import "CDMachOFile.h"
#import "CDFatFile.h"
#import "CDFatArch.h"
#import "CDSearchPathState.h"
#import "CDSymbolsGeneratorVisitor.h"
#import "CDCoreDataModelProcessor.h"
#import "CDSymbolMapper.h"
#import "CDSystemProtocolsProcessor.h"

NSString *defaultSymbolMappingPath = @"symbols.map";

static NSString *const SDK_PATH_PATTERN
        = @"/Applications/Xcode.app/Contents/Developer"
                @"/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator%@.sdk";

void print_usage(void)
{
    fprintf(stderr,
            "PreEmptive Protection for iOS - Rename, version " CLASS_DUMP_VERSION "\n"
            "www.preemptive.com\n"
            "\n"
            "Usage:\n"
            "  ppios-rename --analyze [options] <Mach-O file>\n"
            "  ppios-rename --obfuscate-sources [options]\n"
            "  ppios-rename --translate-crashdump [options] <input file> <output file>\n"
            "  ppios-rename --list-arches <Mach-O file>\n"
            "  ppios-rename --version\n"
            "  ppios-rename --help\n"
            "\n"
            "Common options:\n"
            "  --symbols-map <symbols.map>  Path to symbol map file\n"
            "\n"
            "Additional options for --analyze:\n"
            "  -F '[!]<pattern>'            Filter classes/protocols/categories\n"
            "  -x '<pattern>'               Exclude arbitrary symbols\n"
            "  --arch <arch>                Specify architecture from universal binary\n"
            "  --sdk-root <path>            Specify full SDK root path\n"
            "  --sdk-ios <version>          Specify iOS SDK by version\n"
            "  --framework <name>           Override the detected framework name\n"
            "\n"
            "Additional options for --obfuscate-sources:\n"
            "  --storyboards <path>         Alternate path for XIBs and storyboards\n"
            "  --symbols-header <symbols.h> Path to obfuscated symbol header file\n"
            "\n"
            );
}

#define CD_OPT_ARCH        1
#define CD_OPT_LIST_ARCHES 2
#define CD_OPT_VERSION     3
#define CD_OPT_SDK_IOS     4
#define CD_OPT_SDK_ROOT    6
#define CD_OPT_TRANSLATE_CRASH 10
#define CD_OPT_TRANSLATE_DSYM 11

//Add new arguments below
#define PPIOS_OPT_ANALYZE 12
#define PPIOS_OPT_OBFUSCATE 13
#define PPIOS_OPT_EMIT_EXCLUDES 14
#define PPIOS_OPT_FRAMEWORK_NAME 15
static char* programName;

static NSString *resolveSDKPath(NSFileManager *fileManager,
                                NSString *const sdkRootOption,
                                NSString *const sdkIOSOption);

static NSString *resolveFrameworkRoot(NSFileManager *fileManager,
                                      NSString *const sdkRoot);

static NSArray<NSString *> *assembleClassFilters(CDClassDump *classDump,
                                                 NSArray<NSString *> *commandLineClassFilters);

static NSArray<NSString *> *assembleExclusionPatterns(
        NSArray<NSString *> *commandLineExclusionPatterns);

void printWithFormat(FILE *restrict stream, const char *restrict format, va_list args) {
    fprintf(stream, "%s: ", programName);
    vfprintf(stream, format, args);
    fprintf(stream, "\n");
}

void terminateWithError(int exitCode, const char *format, ...){
    va_list args;
    va_start(args, format);
    printWithFormat(stderr, format, args);
    va_end(args);

    exit(exitCode);
}

void reportWarning(const char *restrict format, ...) {
    va_list args;
    va_start(args, format);
    printWithFormat(stderr, format, args);
    va_end(args);
}

void populateProgramName(char* argv0){
    programName = basename(argv0);
}

void reportSingleModeError(){
    terminateWithError(2, "Only a single mode of operation is supported at a time");
}
void checkOnlyAnalyzeMode(char* flag, BOOL analyze){
    if(!analyze){
        terminateWithError(1, "Argument %s is only valid when using --analyze", flag);
    }
}
void checkOnlyObfuscateMode(char* flag, BOOL obfuscate){
    if(!obfuscate){
        terminateWithError(1, "Argument %s is only valid when using --obfuscate-sources", flag);
    }
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        BOOL shouldAnalyze = NO;
        BOOL shouldObfuscate = NO;
        BOOL shouldListArches = NO;
        BOOL shouldPrintVersion = NO;
        BOOL shouldTranslateCrashDump = NO;
        BOOL shouldShowUsage = NO;
        CDArch targetArch;
        BOOL hasSpecifiedArch = NO;
        NSMutableArray *commandLineClassFilters = [NSMutableArray new];
        NSMutableArray *commandLineExclusionPatterns = [NSMutableArray new];
        NSString *xibBaseDirectory = nil;
        NSString *symbolsPath = nil;
        NSString *symbolMappingPath = nil;
        NSString *sdkRootOption = nil;
        NSString *sdkIOSOption = nil;
        NSString *diagnosticFilesPrefix;
        NSString *frameworkName = nil;

        int ch;
        BOOL errorFlag = NO;

        struct option longopts[] = {
                { "storyboards",             required_argument, NULL, 'X' },
                { "symbols-header",          required_argument, NULL, 'O' },
                { "symbols-map",             required_argument, NULL, 'm' },
                { "arch",                    required_argument, NULL, CD_OPT_ARCH }, //needed?
                { "list-arches",             no_argument,       NULL, CD_OPT_LIST_ARCHES },
                { "emit-excludes",           required_argument, NULL, PPIOS_OPT_EMIT_EXCLUDES },
                { "version",                 no_argument,       NULL, CD_OPT_VERSION },
                { "sdk-ios",                 required_argument, NULL, CD_OPT_SDK_IOS },
                { "sdk-root",                required_argument, NULL, CD_OPT_SDK_ROOT },
                { "analyze",                 no_argument,       NULL, PPIOS_OPT_ANALYZE },
                { "framework",               required_argument, NULL, PPIOS_OPT_FRAMEWORK_NAME },
                { "obfuscate-sources",       no_argument,       NULL, PPIOS_OPT_OBFUSCATE },
                { "translate-crashdump",     no_argument,       NULL, CD_OPT_TRANSLATE_CRASH},
                { "translate-dsym",          no_argument,       NULL, CD_OPT_TRANSLATE_DSYM},
                { "help",                    no_argument,       NULL, 'h'},
                { NULL,                      0,                 NULL, 0 },
        };

        populateProgramName(argv[0]);

        if (argc == 1) {
            print_usage();
            exit(0);
        }

        CDClassDump *classDump = [[CDClassDump alloc] init];
        BOOL hasMode = NO;

        while ( (ch = getopt_long(argc, argv, "F:x:h", longopts, NULL)) != -1) {

            if(!hasMode) {
                //should only run on first iteration
                switch (ch) {
                    case PPIOS_OPT_ANALYZE:
                        shouldAnalyze = YES;
                        break;
                    case PPIOS_OPT_OBFUSCATE:
                        shouldObfuscate = YES;
                        break;
                    case CD_OPT_LIST_ARCHES:
                        shouldListArches = YES;
                        break;
                    case CD_OPT_VERSION:
                        shouldPrintVersion = YES;
                        break;
                    case CD_OPT_TRANSLATE_DSYM:
                        terminateWithError(1, "The --translate-dsym functionality has been replaced.  Please see the documentation.");
                        break;
                    case CD_OPT_TRANSLATE_CRASH:
                        shouldTranslateCrashDump = YES;
                        break;
                    case 'h':
                        shouldShowUsage = YES;
                        break;
                    default:
                        terminateWithError(1, "You must specify the mode of operation as the first argument");
                }
                hasMode = YES;
                continue; //skip this iteration..
            }

            switch (ch) {
                case CD_OPT_ARCH: {
                    checkOnlyAnalyzeMode("--arch", shouldAnalyze);
                    NSString *name = [NSString stringWithUTF8String:optarg];
                    if ([name length] == 0){
                        terminateWithError(1, "--arch must not be blank");
                    }
                    targetArch = CDArchFromName(name);
                    if (targetArch.cputype != CPU_TYPE_ANY)
                        hasSpecifiedArch = YES;
                    else {
                        fprintf(stderr, "Error: Unknown arch %s\n\n", optarg);
                        errorFlag = YES;
                    }
                    break;
                }
                case CD_OPT_SDK_IOS: {
                    checkOnlyAnalyzeMode("--sdk-ios", shouldAnalyze);
                    sdkIOSOption = [NSString stringWithUTF8String:optarg];
                    if ([sdkIOSOption length] == 0){
                        terminateWithError(1, "--sdk-ios must not be blank");
                    }
                    break;
                }
                case CD_OPT_SDK_ROOT: {
                    checkOnlyAnalyzeMode("--sdk-root", shouldAnalyze);
                    sdkRootOption = [NSString stringWithUTF8String:optarg];
                    if ([sdkRootOption length] == 0){
                        terminateWithError(1, "--sdk-root must not be blank");
                    }
                    break;
                }
                case PPIOS_OPT_FRAMEWORK_NAME: {
                    checkOnlyAnalyzeMode("--framework", shouldAnalyze);
                    frameworkName= [NSString stringWithUTF8String:optarg];
                    if ([frameworkName length] == 0){
                        terminateWithError(1, "--framework must not be blank");
                    }
                    break;
                }

                case 'F': {
                    checkOnlyAnalyzeMode("-F", shouldAnalyze);
                    NSString *value = [NSString stringWithUTF8String:optarg];
                    if ([value length] == 0 || ([value length] == 1 && [value hasPrefix:@"!"])){
                        terminateWithError(1, "-F must not be blank");
                    }
                    if ((commandLineClassFilters.count == 0) && ![value hasPrefix:@"!"]) {
                        reportWarning("Warning: include filters without a preceding exclude filter "
                                "have no effect");
                    }
                    [commandLineClassFilters addObject:value];
                    break;
                }

                case 'X':
                    checkOnlyObfuscateMode("--storyboards", shouldObfuscate);
                    xibBaseDirectory = [NSString stringWithUTF8String:optarg];
                    if ([xibBaseDirectory length] == 0){
                        terminateWithError(1, "--storyboards must not be blank");
                    }
                    break;

                case 'O':
                    checkOnlyObfuscateMode("--symbols-header", shouldObfuscate);
                    symbolsPath = [NSString stringWithUTF8String:optarg];
                    if ([symbolsPath length] == 0){
                        terminateWithError(1, "--symbols-header must not be blank");
                    }
                    break;

                case 'm':
                    if(shouldListArches || shouldPrintVersion || shouldShowUsage){
                        terminateWithError(1, "Argument -m is not valid in this context");
                    }
                    symbolMappingPath = [NSString stringWithUTF8String:optarg];
                    if ([symbolMappingPath length] == 0){
                        terminateWithError(1, "--symbols-map must not be blank");
                    }
                    break;

                case 'x': {
                    checkOnlyAnalyzeMode("-x", shouldAnalyze);
                    NSString *value = [NSString stringWithUTF8String:optarg];
                    if ([value length] == 0) {
                        terminateWithError(1, "-x must not be blank");
                    }
                    [commandLineExclusionPatterns addObject:value];
                    break;
                }

                case PPIOS_OPT_EMIT_EXCLUDES:
                    // This option is for testing and diagnosis of behavior.
                    checkOnlyAnalyzeMode("--emit-excludes", shouldAnalyze);
                    diagnosticFilesPrefix = [NSString stringWithUTF8String:optarg];
                    break;

                case PPIOS_OPT_ANALYZE:
                case PPIOS_OPT_OBFUSCATE:
                case CD_OPT_LIST_ARCHES:
                case CD_OPT_VERSION:
                case CD_OPT_TRANSLATE_DSYM:
                case CD_OPT_TRANSLATE_CRASH:
                case 'h':
                    reportSingleModeError();
                    break;
                default:
                    errorFlag = YES;
                    break;
            }

        }
        if (errorFlag) {
            print_usage();
            exit(2);
        }
        if(!hasMode){
            print_usage();
        }
        if(shouldShowUsage){
            print_usage();
            exit(0);
        }

        if (!symbolMappingPath) {
            symbolMappingPath = defaultSymbolMappingPath;
        }

        NSString *firstArg = nil;
        if (optind < argc) {
            if(shouldObfuscate | shouldPrintVersion){
                terminateWithError(1, "Unrecognized additional argument: %s", argv[optind]);
            }
            firstArg = [NSString stringWithFileSystemRepresentation:argv[optind]];
            if([firstArg length] == 0){
                terminateWithError(1, "Arguments must not be blank");
            }
        }
        NSString *secondArg = nil;
        if(optind + 1 < argc ){
            if(!(shouldTranslateCrashDump)){
                terminateWithError(1, "Unrecognized additional argument: %s", argv[optind + 1]);
            }
            secondArg = [NSString stringWithFileSystemRepresentation:argv[optind + 1]];
            if([secondArg length] == 0){
                terminateWithError(1, "Arguments must not be blank");
            }
        }
        if(argc > optind + 2){
            terminateWithError(1, "Unrecognized additional argument: %s", argv[optind + 2]);
        }

        if(!hasMode){
            print_usage();
            exit(2);
        }


        if (shouldPrintVersion) {
            printf("PreEmptive Protection for iOS - Rename, version %s\n", CLASS_DUMP_VERSION);
        } else if (shouldListArches) {
            if(firstArg == nil){
                terminateWithError(1, "Input file must be specified for --list-arches");
            }
            NSString *executablePath = nil;
            executablePath = [firstArg executablePathForFilename];
            if (executablePath == nil) {
                terminateWithError(1, "Input file (%s) doesn't contain an executable.", [firstArg fileSystemRepresentation]);
            }
            CDSearchPathState *searchPathState = [[CDSearchPathState alloc] init];
            searchPathState.executablePath = executablePath;
            id macho = [CDFile fileWithContentsOfFile:executablePath searchPathState:searchPathState];
            if (macho != nil) {
                if ([macho isKindOfClass:[CDMachOFile class]]) {
                    printf("%s\n", [[macho archName] UTF8String]);
                } else if ([macho isKindOfClass:[CDFatFile class]]) {
                    printf("%s\n", [[[macho archNames] componentsJoinedByString:@" "] UTF8String]);
                }
            }
        }else if(shouldAnalyze){
            if(firstArg == nil){
                terminateWithError(1, "Input file must be specified for --analyze");
            }
            NSString *executablePath = nil;
            executablePath = [firstArg executablePathForFilename];
            if (executablePath == nil) {
                terminateWithError(1, "Input file (%s) doesn't contain an executable.", [firstArg fileSystemRepresentation]);
            }
            classDump.searchPathState.executablePath = [executablePath stringByDeletingLastPathComponent];

            NSString *sdkRoot = resolveSDKPath(fileManager, sdkRootOption, sdkIOSOption);
            classDump.headersRoot = sdkRoot;
            classDump.sdkRoot = resolveFrameworkRoot(fileManager, sdkRoot);

            CDFile *file = [CDFile fileWithContentsOfFile:executablePath searchPathState:classDump.searchPathState];
            if (file == nil) {
                if ([fileManager fileExistsAtPath:executablePath]) {
                    if ([fileManager isReadableFileAtPath:executablePath]) {
                        if ([executablePath hasSuffix:@".a"]) {
                            terminateWithError(1, (NOT_MACHO_OR_FAT_MESSAGE " " STATIC_LIBRARY_MESSAGE),
                                               [executablePath UTF8String]);
                        } else {
                            terminateWithError(1, NOT_MACHO_OR_FAT_MESSAGE, [executablePath UTF8String]);
                        }
                    } else {
                        terminateWithError(1, "Input file (%s) is not readable (check read permissions).", [executablePath UTF8String]);
                    }
                } else {
                    terminateWithError(1, "Input file (%s) does not exist.", [executablePath UTF8String]);
                }
            }

            if (hasSpecifiedArch == NO) {
                if ([file bestMatchForLocalArch:&targetArch] == NO) {
                    terminateWithError(1, "Error: Couldn't get local architecture");
                }
            }

            classDump.targetArch = targetArch;
            classDump.searchPathState.executablePath = [executablePath stringByDeletingLastPathComponent];

            NSError *error;
            if (![classDump loadFile:file error:&error depth:0]) {
                terminateWithError(1, "Error: %s", [[error localizedFailureReason] UTF8String]);
            }

            int result = [classDump processObjectiveCData];
            if (result != 0) {
                // errors already reported
                exit(result);
            }
            [classDump registerTypes];
            NSArray<NSString *> *classFilters
                    = assembleClassFilters(classDump, commandLineClassFilters);
            NSArray<NSString *> *exclusionPatterns
                    = assembleExclusionPatterns(commandLineExclusionPatterns);

            CDSymbolsGeneratorVisitor *visitor = [CDSymbolsGeneratorVisitor new];
            visitor.classDump = classDump;
            visitor.classFilters = classFilters;
            visitor.exclusionPatterns = exclusionPatterns;
            visitor.diagnosticFilesPrefix = diagnosticFilesPrefix;
            if (frameworkName) {
                visitor.frameworkName = frameworkName;
            } else {
                NSArray<NSString *> *pathElements = [executablePath pathComponents];
                NSUInteger size = [pathElements count];
                if (size > 1 && [[pathElements objectAtIndex:(size-2)] hasSuffix:@".framework"]) {
                    visitor.frameworkName = [executablePath lastPathComponent];
                } else if ([firstArg hasSuffix:@".framework"]) {
                    visitor.frameworkName = [executablePath lastPathComponent];
                }
            }

            [classDump recursivelyVisit:visitor];
            CDSymbolMapper *mapper = [[CDSymbolMapper alloc] init];
            [mapper writeSymbolsFromSymbolsVisitor:visitor toFile:symbolMappingPath];
        } else if(shouldObfuscate){
            if ((xibBaseDirectory != nil)
                    && ![fileManager fileExistsAtPath:xibBaseDirectory]) {
                terminateWithError(1,
                        "Storyboards directory does not exist %s",
                        [xibBaseDirectory fileSystemRepresentation]);
            }

            int result = [classDump obfuscateSourcesUsingMap:symbolMappingPath
                                           symbolsHeaderFile:symbolsPath
                                            workingDirectory:@"."
                                                xibDirectory:xibBaseDirectory];
            if (result != 0) {
                // errors already reported
                exit(result);
            }
        } else if(shouldTranslateCrashDump) {
            if (!firstArg) {
                terminateWithError(4, "No valid input crash dump file provided");
            }
            if(!secondArg) {
                terminateWithError(4, "No valid output crash dump file provided");
            }
            NSString* crashDumpPath = firstArg;
            NSString* outputCrashDump = secondArg;
            NSString *crashDump = [NSString stringWithContentsOfFile:crashDumpPath encoding:NSUTF8StringEncoding error:nil];
            if (crashDump.length == 0) {
                terminateWithError(4, "Crash dump file does not exist or is empty %s", [crashDumpPath fileSystemRepresentation]);
            }

            NSString *symbolsData = [NSString stringWithContentsOfFile:symbolMappingPath encoding:NSUTF8StringEncoding error:nil];
            if (symbolsData.length == 0) {
                terminateWithError(5, "Symbols file does not exist or is empty %s", [symbolMappingPath fileSystemRepresentation]);
            }

            CDSymbolMapper *mapper = [[CDSymbolMapper alloc] init];
            NSString *processedFile = [mapper processCrashDump:crashDump withSymbols:[NSJSONSerialization JSONObjectWithData:[symbolsData dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]];
            NSError *error;
            [processedFile writeToFile:outputCrashDump atomically:YES encoding:NSUTF8StringEncoding error:&error];
            if(error){
                terminateWithError(4, "Error writing crash dump file: %s", [[error localizedFailureReason] UTF8String]);
            }
        }
        exit(0); // avoid costly autorelease pool drain, we’re exiting anyway
    }
}

static NSArray<NSString *> *assembleClassFilters(CDClassDump *classDump,
                                                 NSArray<NSString *> *commandLineClassFilters) {

    // process CoreData schema
    CDCoreDataModelProcessor *coreDataModelProcessor = [CDCoreDataModelProcessor new];
    NSArray<NSString *> *coreDataClasses = [coreDataModelProcessor coreDataModelSymbolsToExclude];

    // scan for system protocols
    CDSystemProtocolsProcessor *systemProtocolsProcessor
            = [[CDSystemProtocolsProcessor alloc] initWithSdkPath:classDump.headersRoot];
    NSArray<NSString *> *systemProtocols
            = [systemProtocolsProcessor systemProtocolsSymbolsToExclude];
    if (systemProtocols == nil) {
        terminateWithError(1,
                "Unable to process system headers from SDK: %s",
                [classDump.headersRoot UTF8String]);
    }

    // assemble the class filters
    NSMutableArray<NSString *> *classFilters = [NSMutableArray new];

    // Filter out system classes, including auto-generated entities like
    // __ARCLiteKeyedSubscripting__ and __ARCLiteIndexedSubscripting__.
    [classFilters addObject:@"!__*"];

    // Exclude the system protocols as class filters, so that they are noted with "Ignoring"
    // on the command-line output.
    for (NSString *protocolName in systemProtocols) {
        [classFilters addObject:[@"!" stringByAppendingString:protocolName]];
    }

    [classFilters addObjectsFromArray:coreDataClasses];

    // Reversing here the class filters passed on the command-line, means that the more
    // specific rules should be passed last: -F !PP* -F PPPublicThing*
    [classFilters addObjectsFromArray:[commandLineClassFilters reversedArray]];

    return classFilters;
}

static NSArray<NSString *> *assembleExclusionPatterns(
        NSArray<NSString *> *commandLineExclusionPatterns) {

    NSMutableArray<NSString *> *exclusionPatterns = [NSMutableArray new];

    // Explicitly exclude system symbols like: .cxx_destruct
    [exclusionPatterns addObject:@".*"];

    // Explicitly exclude symbols that should be reserved for the compiler/system.
    [exclusionPatterns addObject:@"__*"];

    [exclusionPatterns addObjectsFromArray:commandLineExclusionPatterns];

    return exclusionPatterns;
}

static NSString *resolveSDKPath(NSFileManager *fileManager,
                                NSString *const sdkRootOption,
                                NSString *const sdkIOSOption) {

    if ((sdkRootOption != nil) && (sdkIOSOption != nil)) {
        terminateWithError(1, "Specify only one of --sdk-root or --sdk-ios");
    }

    BOOL specified = YES;
    NSString *sdkPath;
    if (sdkRootOption == nil) {
        NSString *version = sdkIOSOption;
        if (version == nil) {
            specified = NO;
            version = @"";
        }

        sdkPath = [NSString stringWithFormat:SDK_PATH_PATTERN, version];
    } else {
        sdkPath = sdkRootOption;
    }

    if (![fileManager fileExistsAtPath:sdkPath]) {
        terminateWithError(1,
                "%s SDK does not exist: %s",
                (specified ? "Specified" : "Default"),
                [sdkPath UTF8String]);
    }

    return sdkPath;
}

// In Xcode 9, the Framework binaries and header files were moved into separate directory roots.  This method tries to
// resolve the Framework binaries root from the headers root.  The headers root is what has been traditionally specified
// as "the SDK root".
static NSString *resolveFrameworkRoot(NSFileManager *fileManager,
                                      NSString *const sdkRoot) {

    NSRange range = [sdkRoot rangeOfString:@"/Platforms/"];
    if (range.location != NSNotFound) {
        // In Xcode 11, the directories were reordered. Prefer the Xcode 11 order.
        NSUInteger start = range.location + range.length;
        NSRange replaceablePart = NSMakeRange(start, [sdkRoot length] - start);
        for (NSString *simulator in [NSArray arrayWithObjects:@"iPhoneOS.platform/Library/Developer", @"iPhoneOS.platform/Developer/Library", nil]) {
            NSString *candidate = [simulator stringByAppendingString:@"/CoreSimulator/Profiles/Runtimes/iOS.simruntime/Contents/Resources/RuntimeRoot"];
            NSString *root = [sdkRoot stringByReplacingCharactersInRange:replaceablePart withString:candidate];
            if ([fileManager fileExistsAtPath:root]) {
                return root;
            }
        }
    }
    
    return sdkRoot;
}
