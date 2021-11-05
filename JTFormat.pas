// Copyright (c) 2021 Arsanias
// Distributed under the MIT software license, see the accompanying
// file LICENSE or http://www.opensource.org/licenses/mit-license.php.

(*
* The following classes and records can be used to load the complex Siemens JT
* format. The files don't require any DLL to run. I have translated the whole
* Siemens Format into Delphi, so no need for external libraries.
* I have tested the format with JT Versions 8.1 up to 10.5 with success.
* You need my other projects (CORE & GameMachine) to be able to fully use this
* unit, however, you might be able to simply run it by replacing the missing
* unit references with yours.
*)

unit
  JTFormat;

interface

uses
  System.SysUtils, System.Types, System.StrUtils, System.Variants, System.UITypes, System.ZLib,
  System.Classes, System.DateUtils, System.Math,
  Vcl.Dialogs,
  Generics.Defaults, Generics.Collections,
  Core.Utils, Core.Types, Core.ByteReader, Core.Loader,
  JTCodec;

const
  JT_BO_LITTLEENDIAN = 0;
  JT_BO_BIGENDIAN = 1;

  JT_LSG_KEY_PROP_NAME = 'JT_PROP_NAME';
  JT_LSG_KEY_PROP_SHAPE = 'JT_LLPROP_SHAPEIMPL';

  UnknownElementID: TGUID = (D1:$00000000; D2:$0000; D3:$0000; D4:($00, $00, $00, $00, $00, $00, $00, $00));
  EndOfElementsID: TGUID = (D1:$FFFFFFFF; D2:$FFFF; D3:$FFFF; D4:($FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF));

type
  TNodeType = (ntNone, ntGraph, ntAttribute, ntProperty);

  TBaseElement = class                                                          // Basis for all classes
    ObjectID: Cardinal;                                                         // which are constructed
    NodeType: TNodeType;                                                        // over "Loader" parameter
    ChildIndex: Integer; // for internal use --> tree view creation
    constructor Create(Loader: TCoreLoader); virtual; abstract;
    function GetChildCount: Integer;
    function GetAttributeCount: Integer;
    function ToString: string;
  end;
  TBaseElementClass = class of TBaseElement;

  TGUIDToClass = record
    ClassType: TBaseElementClass;
    GUID: TGUID;
  end;

  TSegmentType = (stLogSceneGraph = 1, stBoundaryRep, stPMIData, stMetaData, stShape = 6, stShapeLOD0,
    stShapeLOD1, stShapeLOD2, stShapeLOD3, stShapeLOD4, stShapeLOD5, stShapeLOD6, stShapeLOD7,
    stShapeLOD8, stShapeLOD9, stXTBoundaryRep, stWireFrameRep, stULP = 20, stLWPA, stUnknown = 255);
  TSegmentTypes = set of TSegmentType;

  TObjectBaseType = (otBaseGraphNodeObject = 0, GroupGraphNodeObject, ShapeGraphNodeObject,
    BaseAttributeObject, ShapeLOD, BasePropertyObject, JTObjectReferenceObject, 
    JTLateLoadedPropertyObject, JTBase, UnknownGraphNodeObject = 255);

  TFileHeader = class // V10-018
  const
    JTValidityBytes: array[0..4] of Byte = ($20, $0A, $0D, $0A, $20);
    JTValidityText: array[0..6] of AnsiChar = ('V', 'e', 'r', 's', 'i', 'o', 'n');
  public
    ByteOrder: UInt8;
    EmptyField: Integer;
    TOCOffset: Integer;
    LSGSegmentID: TGUID;
    constructor Create(Loader: TCoreLoader; var AVersion: Single);
  end;

  TQuantizationParameters = record
  public
    BitsPerVertex: Integer;
    NormalBitsFactor: Integer;
    BitsPerTextureCoord: Integer;
    BitsPerColor: Integer;
    constructor Create(Loader: TCoreLoader);
  end;

  TUniformQuantizerData = record // v10.0-177
  public
    Min: Single;
    Max: Single;
    NumBits: Integer;
    function GetRange: TRangeF;
    constructor Create(Loader: TCoreLoader);
    property Range: TRangeF read GetRange;
  end;
  TUniformQuantizerDataArray = array of TUniformQuantizerData;

  TPointQuantizerData = record // V81-244 // V10-174(186)
    UFQDataX: TUniformQuantizerData;
    UFQDataY: TUniformQuantizerData;
    UFQDataZ: TUniformQuantizerData;
    constructor Create(Loader: TCoreLoader);
  end;
  PPointQuantizerData = ^TPointQuantizerData;

  TColorQuantizerData = record
    UniformQuantizerDataRed: TUniformQuantizerData;
    UniformQuantizerDataGreen: TUniformQuantizerData;
    UniformQuantizerDataBlue: TUniformQuantizerData;
    UniformQuantizerDataAlpha: TUniformQuantizerData;
    constructor Create(Loader: TCoreLoader);
  end;

  TTextureQuantizerData = class
    UniformQuantizerDatas: TUniformQuantizerDataArray;
    constructor Create(Loader: TCoreLoader; numberComponents: Integer);
  end;

  TCompressedVertexColorArray = class
    ColorValues: TList<Single>;
    constructor Create(Loader: TCoreLoader);
    destructor Destroy; override;
  end;

  TCompressedVertexFlagArray = class // v10.0-170
    VertexFlagCount: Integer;
    VertexFlags: TIntegerList;
    constructor Create(Loader: TCoreLoader);
    destructor Destroy; override;
  end;

  TCompressedAuxiliaryFieldsArray = class
    //
  end;

  TTopologicallyCompressedVertexRecords = class // v9.5-117 // v10.0-105
    Vertices: TSingleList;
    Normals: TSingleList;
    ColorArray: TCompressedVertexColorArray;
    FlagArray: TCompressedVertexFlagArray;
    constructor Create(Loader: TCoreLoader);
    destructor Destroy; override;
    procedure DecodeCompressedVertexCoordinates(Loader: TCoreLoader); // v9.5-267 // v10.0-164
    procedure DecodeCompressedVertexTextureCoordinates(Loader: TCoreLoader);
    procedure DecodeCompressedVertexNormals(Loader: TCoreLoader); // v9.5-268 // v10.0-165
  end;

  TTopologicallyCompressedRepData = class // v9.5-114 // v10.0-103
    FaceDegrees: TList<TIntegerList>;
    VertexValences: TIntegerList;
    VertexGroups: TIntegerList;
    VertexFlags: TIntegerList;
    FaceAttrMasks: TList<TUInt64List>;
    HighDegreeFaceAttributeMasks: TIntegerDynArray;
    SplitFaces: TIntegerList;
    SplitFacePositions: TIntegerList;
    Hash: Cardinal;
    TopologicallyCompressedVertexRecords: TTopologicallyCompressedVertexRecords;
    constructor Create(Loader: TCoreLoader);
    destructor Destroy; override;
    function CheckHash: Boolean;
  end;

  TTopoMeshLODData = class // v10.0-097
    VersionNumber: Int16;
    VertexRecordsObjectID: Integer;
    constructor Create(Loader: TCoreLoader); virtual;
  end;

  TTopoMeshCompressedLODData = class(TTopoMeshLODData) // v9.5-113 // v10.0-097
    VersionNumber: Int16;
    constructor Create(Loader: TCoreLoader); override;
  end;

  TTopoMeshTopologicallyCompressedLODData = class(TTopoMeshLODData) // v9.5-113 // v10.0-102
    VersionNumber: Int16;
    TopologicallyCompressedRepData: TTopologicallyCompressedRepData;
    constructor Create(Loader: TCoreLoader); override;
    destructor Destroy; override;
  end;

  TVertexBasedShapeCompressedRepData = class // v8.1-234
  private
    NormalBinding: UInt8;
    TextureCoordBinding: UInt8;
    ColorBinding: UInt8;
    procedure LossyQuantizedRawVertexData(Loader: TCoreLoader); // v8.1-237
    procedure LosslessCompressedRawVertexData(Loader: TCoreLoader); // v8.1-236
  public
    Vertices: TSingleList;
    Normals: TSingleList;
    Colors: TSingleList;
    TextureCoordinates: TSingleList;
    PrimitiveListIndices: TIntegerList;
    constructor Create(Loader: TCoreLoader);
    destructor Destroy; override;
  end;

  TQuantizedVertexCoordArray = class  // v8.1-238
  public
    PointQuantizerData: TPointQuantizerData;
    VertexCount: Integer;
    Vertices: TSingleList;
    constructor Create(Loader: TCoreLoader);
  end;

  TQuantizedVertexNormalArray = class // V81-239
     NumberOfBits: UInt8;
     NormalCount: Integer;
     SextantCodes: TIntegerList;
     OctantCodes: TIntegerList;
     ThetaCodes: TIntegerList;
     PsiCodes: TIntegerList;
     Normals: TSingleList;
     constructor Create(Loader: TCoreLoader);
  end;

  TQuantizedVertexColorArray = class // V81-242
    ColorQuantizerData: TPointQuantizerData;
    NumberOfBits: UInt8;
    NumberOfColorFloats: UInt8;
    ComponentArrayFlags: UInt8;
    RedAndHueCodes: TIntegerList;
    GreenAndSatCodes: TIntegerList;
    BlueAndValueCodes: TIntegerList;
    AlphaCodes: TIntegerList;
    ColorCodes: TIntegerList;
    Colors: TList<Single>;
    constructor Create(Loader: TCoreLoader);
  end;

  TQuantizedVertexTextureCoordArray = class
    Textures: TList<Single>;
    constructor Create(Loader: TCoreLoader);
  end;

  TElementHeader = record // v8.1-035 // v9.5-031 // v10.0-024
    ElementLength: Integer;
    ObjectTypeID: TGUID;
    ObjectBaseType: TObjectBaseType;
    ObjectId: Integer;
    SkipLength: Integer;
    constructor Create(Loader: TCoreLoader);
  end;

  TLogicalElementHeaderZLib = class // v8.1-037 // v9.5-032 // v10.0-025
  protected
    type TCompressionType = (caUndefined, caNone, caZLib, caLZMA);
  public
    CompressionFlag: Integer;
    CompressedDataLength: Integer;
    CompresionAlogirthm: TCompressionType;
    constructor Create(Loader: TCoreLoader);
  end;

  TSegmentHeader = record // v8.1-033 // v9.5-029
    GUID: TGUID;
    SegmentType: TSegmentType;
    SegmentLength: Integer;
    constructor Create(Loader: TCoreLoader);
  end;

  TTOCEntry = class // V81-031 // V95-028 // V10-020(032)
  private
    function GetSegmentType: TSegmentType;
  public
    SegmentID: TGUID;
    SegmentOffset: Int64;
    SegmentLength: Integer;
    SegmentAttributes: Cardinal;
    constructor Create(Loader: TCoreLoader);
    property SegmentType: TSegmentType read GetSegmentType;
  end;

  TBaseNodeElement = class(TBaseElement) // v8.1-040 // v9.5-035 // v10.0-029
    VersionNumber: Int16; // v9.5 // v10.0
    NodeFlags: Cardinal;
    AttrCount: Integer;
    AttrObjectIDs: TIntegerDynArray;
    constructor Create(Loader: TCoreLoader); override;
  end;

  TGroupNodeElement = class(TBaseNodeElement) // v8.1-044 // v9.5-039 // v10.0-033
    VersionNumber: Int16; // v9.5
    ChildCount: Integer;
    ChildNodeObjectIDs: TIntegerDynArray;
    constructor Create(Loader: TCoreLoader); override;
  end;

  TPartitionNodeElement = class(TGroupNodeElement) // v8.1-041 // v9.5-036 // v10.0-030
    VersionNumber: Byte; // v10.0
    PartitionFlags: Integer; // $0001 = Untransformed Bounding Box
    Filename: string;
    ReservedField: TBoundingBox; // (PartitionFlags & $01) <> 0
    TransformedBox: TBoundingBox; // (PartitionFlags & $01) = 0
    Area: Single;
    VertexCountRange: TRange;
    NodeCountRange: TRange;
    PolygonCountRange: TRange;
    UntransformedBox: TBoundingBox; // (PartitionFlags & $01) <> 0
    constructor Create(Loader: TCoreLoader); override;
  end;

  TInstanceNodeElement = class(TBaseNodeElement) // v8.1-045 // v9.5-039 // v10.0-034
    VersionNumber: Int16; // V9.5
    ChildNodeObjectID: Integer;
    constructor Create(Loader: TCoreLoader); override;
  end;

  TMetaDataNodeElement = class(TGroupNodeElement) // v8.1-047 // v9.5-041 // v10.0-036
    VersionNumber: Int16;
    constructor Create(Loader: TCoreLoader); override;
  end;

  TPartNodeElement = class(TMetaDataNodeElement) // v8.1-046 // v9.5-040 // v10.0-035
    VersionNumber: Int16;
    ReservedField: Integer;
    constructor Create(Loader: TCoreLoader); override;
  end;

  TLODNodeElement = class(TGroupNodeElement) // v8.1-048 // v9.5-041 // v10.0-037
    VersionNumber: Int16; // v9.5 // v10.0
    ReservedVector: TSingleDynArray; // v8.1 // v9.5
    ReservedField: Integer; // v8.1 // v9.5
    constructor Create(Loader: TCoreLoader); override;
  end;

  TRangeLODNodeElement = class(TLODNodeElement) // v8.1-049 // v9.5-043 // v10.0-037
    VersionNumber: Int16; // v9.5 // v10.0
    RangeLimits: TSingleDynArray;
    Center: TVector3;
    constructor Create(Loader: TCoreLoader); override;
  end;

  TSwitchNodeElement = class(TGroupNodeElement) // v8.1-50 // v9.5-043 // v10.0-038
    VersionNumber: Int16;
    SelectedChild: Integer;
    constructor Create(Loader: TCoreLoader); override;
  end;

  TBaseShapeNodeElement = class(TBaseNodeElement) // v8.1-052 // v9.5-045 // v10.0-039
    VersionNumber: Int16; // v9.5 // v10.0
    TransformedBox: TBoundingBox;
    UntransformedBox: TBoundingBox;
    Area: Single;
    VertexCountRange: TRange;
    NodeCountRange: TRange;
    PolygonCountRange: TRange;
    Size: Integer;
    CompressionLevel: Single;
    constructor Create(Loader: TCoreLoader); override;
  end;

  TVertexShapeNodeElement = class(TBaseShapeNodeElement) // v8.1-055 // v9.5-048 // v10.0-042
    VersionNumber: Int16; // v9.5 // v10.0
    VertexBinding: Int64; // v9.5 // v10.0
    NormalBinding: Integer;
    TextureCoordBinding: Integer;
    ColorBinding: Integer;
    QuantizationParams: TQuantizationParameters;
    constructor Create(Loader: TCoreLoader); override;
  end;

  TTriStripSetShapeNodeElement = class(TVertexShapeNodeElement) // v8.1-058 // v9.5-049
    constructor Create(Loader: TCoreLoader); override;
  end;

  TPolylineSetShapeNodeElement = class(TVertexShapeNodeElement) // v8.1-058 // v9.5-049 // v10.0-043
    VersionNumber: Int16; // v9.5 // v10.0
    AreaFactor: Single;
    VertexBindings: Int64; // v9.5
    constructor Create(Loader: TCoreLoader); override;
  end;

  TPointSetShapeNodeElement = class(TVertexShapeNodeElement) // V8.1-059 // V9.5-050 // v10.0-044
    VersionNumber: Int16; // v9.5 // v10.0
    AreaFactor: Single;
    VertexBindings: Int64; // v9.5 // v10.0
    constructor Create(Loader: TCoreLoader); override;
  end;

  TBaseAttributeElement = class(TBaseElement) // v8.1-065 // v9.5-055 // v10.0-049
    VersionNumber: Int16; // v9.5 // v10.0
    StateFlags: Byte;
    FieldInhibitFlags: Cardinal;
    FieldFinalFlags: Cardinal; // v10.0
    constructor Create(Loader: TCoreLoader); override;
  end;

  TMaterialAttributeElement = class(TBaseAttributeElement) // v8.1-066 // v9.5-061 // v10.0-050
    VersionNumber: Int16; // v9.5 // v10.0
    DataFlag: Int16;
    AmbientColor: TVector4;
    DiffuseColor: TVector4;
    SpecularColor: TVector4;
    EmissionColor: TVector4;
    Shineniness: Single;
    Reflectivity: Single; // v9.5
    Bumpiness: Single; // v10.0
    constructor Create(Loader: TCoreLoader); override;
  end;

  TGeometricTransformAttributeElement = class(TBaseAttributeElement) // v8.1
    VersionNumber: Integer;
    ElementValues: array[0..15] of Double;
    constructor Create(Loader: TCoreLoader); override;
  end;

  TBasePropertyAtomElement = class(TBaseElement) // v8.1-110 // v9.5-101 // v10.0-083
    VersionNumber: Int16; // v9.5 // v10.0
    StateFlags: Cardinal;
    constructor Create(Loader: TCoreLoader); override;
  end;

  TStringPropertyAtomElement = class(TBasePropertyAtomElement) // v8.1-111 // v9.5-101 // v10.0-084
    VersionNumber: Int16; // v9.5 // v10.0
    Value: string;   
    constructor Create(Loader: TCoreLoader); override;
  end;

  TIntegerPropertyAtomElement = class(TBasePropertyAtomElement) // v8.1-111 // v9.5-102
    VersionNumber: Int16; // v9.5
    Value: Integer;
    constructor Create(Loader: TCoreLoader); override;
  end;

  TFloatingPointPropertyAtomElement = class(TBasePropertyAtomElement) // v8.1-112 // v9.5-103
    VersionNumber: Int16; // v9.5
    Value: Single;
    constructor Create(Loader: TCoreLoader); override;
  end;

  TObjectReferencePropertyAtomElement = class(TBasePropertyAtomElement) // v8.1-113 // v9.5-103
    VersionNumber: Int16; // v9.5
    ReferenceID: Integer;
    constructor Create(Loader: TCoreLoader); override;
  end;

  TDatePropertyAtomElement = class(TBasePropertyAtomElement) // v8.1-113 // v9.5-104 // v10.0-086
    VersionNumber: Int16; // v9.5 // v10.0
    Date: TDateTime;
    constructor Create(Loader: TCoreLoader); override;
  end;

  TLateLoadedPropertyAtomElement = class(TBasePropertyAtomElement) // v8.1-115 // v9.5-106 // v10.0-088 // v10.5-105
    VersionNumber: Int16; // v9.5 // v10.0
    SegmentID: TGUID;
    SegmentType: TSegmentType;
    PayloadObjectID: Integer; // v9.5 // v10.0
    Reserved: Integer; // v9.5 // v10.0??
    constructor Create(Loader: TCoreLoader); override;
  end;

  PNodePropertyTable = ^TNodePropertyTable;
  TNodePropertyTable = record
    KeyPropertyAtomObjectID: Integer;
    ValuePropertyAtomObjectID: Integer;
    constructor Create(AKey, AValue: Integer);
  end;

  TNodePropertyTableList = class(TList<PNodePropertyTable>)
    NodeObjectID: Integer;
  end;
  
  TPropertyTable = class // v10.0-090
    VersionNumber: Int16;
    NodePropertyTableCount: Integer;
    NodePropertyTables: array of TNodePropertyTableList;
    constructor Create(Loader: TCoreLoader);
    destructor Destroy; override;
  end;

  TBaseShapeLODElement = class(TBaseElement) // v8.1-XXX // v9.5-109 // v10.0-097(109)
    VersionNumber: Int16;
    constructor Create(Loader: TCoreLoader); override;
  end;

  TVertexShapeLODElement = class(TBaseShapeLODElement) // v8.1-118 // v9.5-110 // v10.0-095
    VersionNumber: Int16;
    VertexBindings: UInt64; // v8.1 = Integer
    QuantizationParameters: TQuantizationParameters; // v8.1
    TopoMeshCompressedLODData: TTopoMeshCompressedLODData; // v9.5
    TopoMeshTopologicallyCompressedLODData: TTopoMeshTopologicallyCompressedLODData; // v9.5
    constructor Create(Loader: TCoreLoader); override;
    destructor Destroy; override;
  end;

  TTriStripSetShapeLODElement = class(TVertexShapeLODElement) // v8.1-120 // v95-124 // v10.0-092
    VersionNumber: Int16;
    VtexBasedShapeComprRepData: TVertexBasedShapeCompressedRepData; // v8.1
    constructor Create(Loader: TCoreLoader); override;
    destructor Destroy; override;
  end;

  TPolyLineSetShapeLODElement = class(TVertexShapeLODElement)
    VersionNumber: Int16;
    constructor Create(Loader: TCoreLoader); override;
    destructor Destroy; override;
  end;

  TDataSegment = class // v8.1-032 // v9.5-029
  protected
    const
    ObjectTypeIDCount = 22;
    ObjectTypeIDs : array[0..ObjectTypeIDCount - 1] of TGUIDToClass = (
      { LSG Segment }
      (ClassType:TInstanceNodeElement;                 GUID:(D1:$10DD102A; D2:$2AC8; D3:$11D1; D4:($9B, $6B, $00, $80, $C7, $BB, $59, $97));),
      (ClassType:TGroupNodeElement;                    GUID:(D1:$10DD101B; D2:$2AC8; D3:$11D1; D4:($9B, $6B, $00, $80, $C7, $BB, $59, $97));),
      (ClassType:TLODNodeElement;                      GUID:(D1:$10DD102C; D2:$2AC8; D3:$11D1; D4:($9B, $6B, $00, $80, $C7, $BB, $59, $97));),
      (ClassType:TPartitionNodeElement;                GUID:(D1:$10DD103E; D2:$2AC8; D3:$11D1; D4:($9B, $6B, $00, $80, $C7, $BB, $59, $97));),
      (ClassType:TRangeLODNodeElement;                 GUID:(D1:$10DD104C; D2:$2AC8; D3:$11D1; D4:($9B, $6B, $00, $80, $C7, $BB, $59, $97));),
      (ClassType:TSwitchNodeElement;                   GUID:(D1:$10DD10F3; D2:$2AC8; D3:$11D1; D4:($9B, $6B, $00, $80, $C7, $BB, $59, $97));),
      (ClassType:TPartNodeElement;                     GUID:(D1:$CE357244; D2:$38FB; D3:$11D1; D4:($A5, $06, $00, $60, $97, $BD, $C6, $E1));),
      (ClassType:TMetaDataNodeElement;                 GUID:(D1:$CE357245; D2:$38FB; D3:$11D1; D4:($A5, $06, $00, $60, $97, $BD, $C6, $E1));),
      (ClassType:TTriStripSetShapeNodeElement;         GUID:(D1:$10DD1077; D2:$2AC8; D3:$11D1; D4:($9B, $6B, $00, $80, $C7, $BB, $59, $97));),
      (ClassType:TPolylineSetShapeNodeElement;         GUID:(D1:$10DD1046; D2:$2AC8; D3:$11D1; D4:($9B, $6B, $00, $80, $C7, $BB, $59, $97));),
      (ClassType:TPointSetShapeNodeElement;            GUID:(D1:$98134716; D2:$0010; D3:$0818; D4:($19, $98, $08, $00, $09, $83, $5D, $5A));),
      (ClassType:TGeometricTransformAttributeElement;  GUID:(D1:$10DD1083; D2:$2AC8; D3:$11D1; D4:($9B, $6B, $00, $80, $C7, $BB, $59, $97));),
      (ClassType:TMaterialAttributeElement;            GUID:(D1:$10DD1030; D2:$2AC8; D3:$11D1; D4:($9B, $6B, $00, $80, $C7, $BB, $59, $97));),
      (ClassType:TStringPropertyAtomElement;           GUID:(D1:$10DD106E; D2:$2AC8; D3:$11D1; D4:($9B, $6B, $00, $80, $C7, $BB, $59, $97));),
      (ClassType:TIntegerPropertyAtomElement;          GUID:(D1:$10DD102B; D2:$2AC8; D3:$11D1; D4:($9B, $6B, $00, $80, $C7, $BB, $59, $97));),
      (ClassType:TFloatingPointPropertyAtomElement;    GUID:(D1:$10DD1019; D2:$2AC8; D3:$11D1; D4:($9B, $6B, $00, $80, $C7, $BB, $59, $97));),
      (ClassType:TObjectReferencePropertyAtomElement;  GUID:(D1:$10DD1004; D2:$2AC8; D3:$11D1; D4:($9B, $6B, $00, $80, $C7, $BB, $59, $97));),
      (ClassType:TDatePropertyAtomElement;             GUID:(D1:$CE357246; D2:$38FB; D3:$11D1; D4:($A5, $06, $00, $60, $97, $BD, $C6, $E1));),
      (ClassType:TLateLoadedPropertyAtomElement;       GUID:(D1:$E0B05BE5; D2:$FBBD; D3:$11D1; D4:($A3, $A7, $00, $AA, $00, $D1, $09, $54));),
      { Shape LOD Segment }
      (ClassType:TVertexShapeLODElement;               GUID:(D1:$10DD10B0; D2:$2AC8; D3:$11D1; D4:($9B, $6B, $00, $80, $C7, $BB, $59, $97));),
      (ClassType:TTriStripSetShapeLODElement;          GUID:(D1:$10DD10AB; D2:$2AC8; D3:$11D1; D4:($9B, $6B, $00, $80, $C7, $BB, $59, $97));),
      (ClassType:TPolyLineSetShapeLODElement;          GUID:(D1:$10DD10A1; D2:$2Ac8; D3:$11D1; D4:($9B, $6B, $00, $80, $C7, $BB, $59, $97));)
    );
  public
    SegmentHeader: TSegmentHeader;
    ElementHeader: TElementHeader;
    class function GetClassByObjectTypeId(const AObjectTypeId: TGUID; var ABaseElementClass: TBaseElementClass): Boolean;
    constructor Create(Loader: TCoreLoader; Offset: Int64); virtual;
    function SupportsZLib: Boolean;
  end;

  TLSGSegment = class(TDataSegment) // v8.1-039 // v10.0-28
  public
    Elements: TList<TBaseElement>;
    PropertyTable: TPropertyTable;
    PropertyStartIndex: Integer;
    function GetPropertyValue(ANodeObjectID: Integer; ACode: string): Variant;
    function GetLateLoadedSegmentID(ANodeObjectID: Integer; ACode: string; var AGUID: TGUID): Boolean;
    constructor Create(Loader: TCoreLoader; Offset: Int64); override;
    destructor Destroy; override;
    function FindElement(AObjectID: Cardinal; var AElement: TBaseElement): Boolean;
  end;

  TShapeLODSegment = class(TDataSegment) // v8.1-117 // v9.5-110 // v10.0-092
  public                     
    Element: TBaseShapeLODElement;
    constructor Create(Loader: TCoreLoader; Offset: Int64); override;
    destructor Destroy; override;
  end;

implementation

var
  DebugPointer: TList<TIntegerList> = nil;

//==============================================================================

constructor TQuantizationParameters.Create(Loader: TCoreLoader);
begin
  BitsPerVertex := Loader.Read8;
  NormalBitsFactor := Loader.Read8;
  BitsPerTextureCoord := Loader.Read8;
  BitsPerColor := Loader.Read8;
end;

//==============================================================================

constructor TUniformQuantizerData.Create(Loader: TCoreLoader);
begin
  Min := Loader.ReadF32;
  Max := Loader.ReadF32;
  NumBits := Loader.Read8;

  if ((NumBits < 0) or (NumBits > 32)) then
    raise Exception.Create('WARNING", "Found unexpected number of bits: ' + IntToSTr(NumBits));
end;

function TUniformQuantizerData.GetRange: TRangeF;
begin
  Result.Min := Min;
  Result.Max := Max;
end;

//==============================================================================

constructor TPointQuantizerData.Create(Loader: TCoreLoader);
begin
  UFQDataX := TUniformQuantizerData.Create(Loader);
  UFQDataY := TUniformQuantizerData.Create(Loader);
  UFQDataZ := TUniformQuantizerData.Create(Loader);

  if ((UFQDataX.NumBits <> UFQDataY.NumBits) or
    (UFQDataX.NumBits <> UFQDataZ.NumBits)) then
    raise Exception.Create('TPointQuantizerData : Create'#13 + 'Number of quantized bits differs!');
end;

//==============================================================================

constructor TColorQuantizerData.Create(Loader: TCoreLoader);
var
  NumberOfHueBits: Integer;
  NumberOfSaturationBits: Integer;
  NumberOfValueBits: Integer;
  NumberOfAlphaBits: Integer;
  HSVFlag: Integer;
begin
  HSVFlag := Loader.Read8;
  if ((HSVFlag <> 0) and (HSVFlag <> 1)) then
    raise Exception.Create('TColorQuantizerData : Create'#13 + 'Found invalid HSV flag: ' + IntToStr(HSVFlag));

  if (HSVFlag = 1) then
  begin
    NumberOfHueBits := Loader.Read8;
    NumberOfSaturationBits := Loader.Read8;
    NumberOfValueBits := Loader.Read8;
    NumberOfAlphaBits := Loader.Read8;
  end
  else
  begin
    UniformQuantizerDataRed := TUniformQuantizerData.Create(Loader);
    UniformQuantizerDataGreen := TUniformQuantizerData.Create(Loader);
    UniformQuantizerDataBlue := TUniformQuantizerData.Create(Loader);
    UniformQuantizerDataAlpha := TUniformQuantizerData.Create(Loader);
  end;
end;

//==============================================================================

constructor TCompressedVertexColorArray.Create(Loader: TCoreLoader);
var
  colorCount: Integer;
  NumComponents: Integer;
  QuantizationBits: Integer;
  vertexColorExponentsLists: TList<TIntegerList>;
  vertexColorMantissaeLists: TList<TIntegerList>;
  vertexColorCodeLists: TList<TIntegerList>;
  ColorQuantizerData: TColorQuantizerData;
  hueRedCodes: TIntegerList;
  satGreenCodes: TIntegerList;
  valueBlueCodes: TIntegerList;
  alphaCodes: TIntegerList;
  exponents: TIntegerList;
  mantissae: TIntegerList;
  codeData: TIntegerList;
  redCodeData: TIntegerList;
  greenCodeData: TIntegerList;
  blueCodeData: TIntegerList;
  RedValues, GreenValues, BlueValues: TList<Single>;
  readHash: Int64;
  i, j: Integer;
begin
  vertexColorExponentsLists := TList<TIntegerList>.Create;
  vertexColorMantissaeLists := TList<TIntegerList>.Create;
  vertexColorCodeLists := TList<TIntegerList>.Create;

  ColorCount := Loader.Read32;
  NumComponents := Loader.Read8;
  QuantizationBits := Loader.Read8;

  if (quantizationBits = 0) then
  begin
    for i := 0 to NumComponents - 1 do
    begin
      Exponents := TIntCDP.ReadVecI32(Loader, TPredictorType.ptPredLag1);
      Mantissae := TIntCDP.ReadVecI32(Loader, TPredictorType.ptPredLag1);

      CodeData := CreateIntegerList(Exponents.Count);
      for j := 0 to Exponents.Count - 1 do
        CodeData.add((Exponents[j] shl 23) or Mantissae[j]);

      vertexColorExponentsLists.add(exponents);
      vertexColorMantissaeLists.add(mantissae);
      vertexColorCodeLists.add(codeData);
    end;

    RedCodeData := VertexColorCodeLists[0];
    GreenCodeData := VertexColorCodeLists[1];
    BlueCodeData := VertexColorCodeLists[2];

    ColorValues := CreateSingleList(RedCodeData.Count * 3);
    for i := 0 to RedCodeData.Count - 1 do
    begin
      ColorValues.Add(IntAsFloat(RedCodeData[i]));
      ColorValues.Add(IntAsFloat(GreenCodeData[i]));
      ColorValues.Add(IntAsFloat(BlueCodeData[i]));
    end;
  end
  else
  if (quantizationBits > 0) then
  begin
    ColorQuantizerData := TColorQuantizerData.Create(Loader);

    HueRedCodes    := TIntCDP.ReadVecI32(Loader, TPredictorType.ptPredLag1);
    SatGreenCodes  := TIntCDP.ReadVecI32(Loader, TPredictorType.ptPredLag1);
    ValueBlueCodes := TIntCDP.ReadVecI32(Loader, TPredictorType.ptPredLag1);
    AlphaCodes     := TIntCDP.ReadVecI32(Loader, TPredictorType.ptPredLag1);

    RedValues := Loader.Dequantize(hueRedCodes, ColorQuantizerData.UniformQuantizerDataRed.Range, quantizationBits);
    GreenValues := Loader.Dequantize(satGreenCodes, ColorQuantizerData.UniformQuantizerDataGreen.Range, quantizationBits);
    BlueValues := Loader.Dequantize(valueBlueCodes, ColorQuantizerData.UniformQuantizerDataBlue.Range, quantizationBits);

    ColorValues := CreateSingleList(RedValues.Count * 3);
    for i := 0 to RedValues.Count - 1 do
    begin
      ColorValues.Add(RedValues[i]);
      ColorValues.Add(GreenValues[i]);
      ColorValues.Add(BlueValues[i]);
    end;
  end
  else
    raise Exception.Create('TCompressedVertexColorArray : Crate'#13 + 'Negative number of quantized bits: ' + IntToStr(QuantizationBits));

  ReadHash := Loader.Read32;
end;

destructor TCompressedVertexColorArray.Destroy;
begin
  if Assigned(ColorValues) then ColorValues.Free;

  inherited;
end;

//==============================================================================

constructor TTextureQuantizerData.Create(Loader: TCoreLoader; NumberComponents: Integer);
var
  i: Integer;
  UniformQuantizerDatas: TUniformQuantizerDataArray;
begin
  SetLength(UniformQuantizerDatas, NumberComponents);

  for i := 0 to NumberComponents - 1 do
    UniformQuantizerDatas[i] := TUniformQuantizerData.Create(Loader);
end;

//==============================================================================

constructor TCompressedVertexFlagArray.Create(Loader: TCoreLoader);
begin
  VertexFlagCount := Loader.Read32;
  VertexFlags := TIntCDP.ReadVecI32(Loader, TPredictorType.ptPredNULL);
end;

destructor TCompressedVertexFlagArray.Destroy;
begin
  SafeFree(VertexFlags);
  inherited;
end;

//==============================================================================

constructor TTopologicallyCompressedVertexRecords.Create(Loader: TCoreLoader);
var
  VertexBindings: Int64;
  QuantizationParameters: TQuantizationParameters;
  NumberOfTopologicalVertices: Integer;
  NumberOfVertexAttributes: Integer;
begin
  ColorArray := nil;
  FlagArray := nil;

  VertexBindings := Loader.Read64;
  QuantizationParameters := TQuantizationParameters.Create(Loader);
  NumberOfTopologicalVertices := Loader.Read32;

  if (NumberOfTopologicalVertices > 0) then
  begin
    NumberOfVertexAttributes := Loader.Read32; // Total number of vertices?

    if ((VertexBindings and $07) <> 0) then		// Check for bits 1-3
      DecodeCompressedVertexCoordinates(Loader);

    if ((VertexBindings and $08) <> 0) then		// Check for bit 4
      DecodeCompressedVertexNormals(Loader);

    if ((VertexBindings and $30) <> 0) then		// Check for bits 5-6
      ColorArray := TCompressedVertexColorArray.Create(Loader);

    if ((VertexBindings and $FFFFFFFF00) <> 0) then	// Check for bits 9-40
      DecodeCompressedVertexTextureCoordinates(Loader);

    if ((VertexBindings and $40) <> 0) then 	// Check for bit 7
      FlagArray := TCompressedVertexFlagArray.Create(Loader);

    if ((VertexBindings and $4000000000000000) > 0) then
      TCompressedAuxiliaryFieldsArray.Create;

    // TODO : texturecoord is obsolete und auxillary nur ein dummy
  end;
end;

destructor TTopologicallyCompressedVertexRecords.Destroy;
begin
  SafeFree(Vertices);
  SafeFree(Normals);
  SafeFree(ColorArray);
  SafeFree(FlagArray);
  inherited;
end;

procedure TTopologicallyCompressedVertexRecords.DecodeCompressedVertexCoordinates(Loader: TCoreLoader);
var
  AExponents: TIntegerList;
  AMantissae: TIntegerList;
  ACodeData: TIntegerList;
  XValues, YValues, ZValues: TList<Single>;
  Xi, Yi, Zi: Integer;
  i, j: Integer;
  AHash, AExpectedHash, AValue: Cardinal;
  UniqueVertexCount: Integer;
  NumberComponents: Integer;
  QuantizerData: TPointQuantizerData;
  BinVertexCoords: TList<TIntegerList>; // V10.0
begin
  { Reset memory pointers }

  BinVertexCoords := nil;
  AExponents := nil;  AMantissae := nil; ACodeData := nil;
  XValues := nil;     YValues := nil;   ZValues := nil;

  UniqueVertexCount := Loader.Read32;
  NumberComponents := Loader.Read8;
  QuantizerData := TPointQuantizerData.Create(Loader);

  BinVertexCoords := TList<TIntegerList>.Create;

  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
  begin
    if (QuantizerData.UFQDataX.NumBits = 0) then
    begin
      for i := 0 to NumberComponents - 1 do
      begin
        AExponents := TIntCDP.ReadVecI32(Loader, TPredictorType.ptPredLag1);
        AMantissae := TIntCDP.ReadVecI32(Loader, TPredictorType.ptPredLag1);

        ACodeData := CreateIntegerList(AExponents.Count);
        for j := 0 to AExponents.Count - 1 do
          ACodeData.Add((AExponents[j] shl 23) or AMantissae[j]);

        BinVertexCoords.Add(ACodeData);
      end;

      Vertices := CreateSingleList(UniqueVertexCount * 3);
      for i := 0 to BinVertexCoords[0].Count - 1 do
      begin
        Vertices.Add(IntAsFloat(BinVertexCoords[0][i])); // X
        Vertices.Add(IntAsFloat(BinVertexCoords[1][i])); // Y
        Vertices.Add(IntAsFloat(BinVertexCoords[2][i])); // Z
      end;
    end
    else
    if (QuantizerData.UFQDataX.NumBits > 0) then
    begin
      BinVertexCoords.Add(TIntCDP.ReadVecI32(Loader, TPredictorType.ptPredLag1));
      BinVertexCoords.Add(TIntCDP.ReadVecI32(Loader, TPredictorType.ptPredLag1));
      BinVertexCoords.Add(TIntCDP.ReadVecI32(Loader, TPredictorType.ptPredLag1));

      XValues := Loader.Dequantize(BinVertexCoords[0], QuantizerData.UFQDataX.Range, QuantizerData.UFQDataX.NumBits);
      YValues := Loader.Dequantize(BinVertexCoords[1], QuantizerData.UFQDataY.Range, QuantizerData.UFQDataX.NumBits);
      ZValues := Loader.Dequantize(BinVertexCoords[2], QuantizerData.UFQDataZ.Range, QuantizerData.UFQDataX.NumBits);

      Vertices := CreateSingleList(XValues.Count * 3);
      for i := 0 to XValues.Count - 1 do
      begin
        Vertices.Add(XValues[i]);
        Vertices.Add(YValues[i]);
        Vertices.Add(ZValues[i]);
      end;
    end
    else
      Raise Exception.Create('TCompressedVertexCoordinateArray : Create'#13 + 'Negative number of quantized bits');
  end
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 10.5)) then
  begin
    if (QuantizerData.UFQDataX.NumBits = 0) then
    begin
      BinVertexCoords := TList<TIntegerList>.Create;
      for i := 0 to NumberComponents - 1 do
        BinVertexCoords.Add(TIntCDP.ReadVecI32(Loader, ptPredLag1));

      Vertices := CreateSingleList(BinVertexCoords[0].Count * 3);
      for i := 0 to BinVertexCoords[0].Count - 1 do
      begin
        Xi := BinVertexCoords[0][i];
        Yi := BinVertexCoords[1][i];
        Zi := BinVertexCoords[2][i];

        Vertices.Add(PSingle(@Xi)^);
        Vertices.Add(PSingle(@Yi)^);
        Vertices.Add(PSingle(@Zi)^);
      end;
    end
    else
    begin
      BinVertexCoords := TList<TIntegerList>.Create;
      for i := 0 to NumberComponents - 1 do
        BinVertexCoords.Add(TIntCDP.ReadVecI32(Loader, ptPredLag1));
    end;
  end;

  AHash := Loader.Read32;
  if (QuantizerData.UFQDataX.NumBits = 0 ) then
  begin
    for i := 0 to NumberComponents - 1 do
      for j := 0 to BinVertexCoords[i].Count - 1 do
      begin
        AValue := BinVertexCoords[i][j];
        AExpectedHash := Hash32(@AValue, 4, AExpectedHash);
      end;
  end
  else
    for i := 0 to BinVertexCoords.Count - 1 do
      AExpectedHash := Hash32(BinVertexCoords[i].List, BinVertexCoords[i].Count, AExpectedHash);

  { Free temporary memory }

  SafeFree(AExponents);
  SafeFree(AMantissae);
  SafeFree(XValues);
  SafeFree(YValues);
  SafeFree(ZValues);
  SafeFree(BinVertexCoords);

  if (BinVertexCoords <> nil) then
  begin
    for i := 0 to BinVertexCoords.Count - 1 do
      BinVertexCoords[i].Free;
    BinVertexCoords.Free;
  end;
end;

procedure TTopologicallyCompressedVertexRecords.DecodeCompressedVertexNormals(Loader: TCoreLoader);
var
  NormalCount: Integer;
  NumberComponents: Byte;
  QuantizationBits: Byte;
  SextantCodes, OctantCodes, ThetaCodes, PsiCodes: TIntegerList;
  NormalVectorLists: TList<TIntegerList>;
  Exponents, Mantissae: TIntegerList;
  NormalVectorData: TIntegerList;
  BinaryVertexNormals: TList<TIntegerList>;
  DeeringNormalCodes: TIntegerList;
  Xi, Yi, Zi: Integer;
  Normal: TVector3;
  ReadHash: Cardinal;
  i, j: Integer;
begin
  SextantCodes := nil;
  OctantCodes := nil;
  ThetaCodes := nil;
  PsiCodes := nil;
  Exponents := nil;
  Mantissae := nil;
  NormalVectorData := nil;
  NormalVectorLists := nil;
  BinaryVertexNormals := nil;
  DeeringNormalCodes := nil;

  NormalCount := Loader.Read32;
  NumberComponents := Loader.Read8;
  QuantizationBits := Loader.Read8;

  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
  begin
    NormalVectorLists := TList<TIntegerList>.Create;

    if (QuantizationBits = 0) then
    begin
      for i := 0 to NumberComponents - 1 do
      begin
        Exponents := TIntCDP.ReadVecI32(Loader, TPredictorType.ptPredNULL);
        Mantissae := TIntCDP.ReadVecI32(Loader, TPredictorType.ptPredNULL);

        NormalVectorData := CreateIntegerList(Exponents.Count);
        for j := 0 to Exponents.Count - 1 do
          NormalVectorData.Add((Exponents[j] shl 23) or Mantissae[j]);

        NormalVectorLists.Add(NormalVectorData);
      end;

      Normals := CreateSingleList(NormalVectorLists[0].Count * 3);
      for i := 0 to NormalVectorLists[0].Count - 1 do
      begin
        Normals.Add(IntAsFloat(NormalVectorLists[0][i])); // X
        Normals.Add(IntAsFloat(NormalVectorLists[1][i])); // Y
        Normals.Add(IntAsFloat(NormalVectorLists[2][i])); // Z
      end;
    end
    else
    if (QuantizationBits > 0) then
    begin
      SextantCodes := TIntCDP.ReadVecI32(Loader, TPredictorType.ptPredNULL);
      OctantCodes := TIntCDP.ReadVecI32(Loader, TPredictorType.ptPredNULL);
      ThetaCodes := TIntCDP.ReadVecI32(Loader, TPredictorType.ptPredNULL);
      PsiCodes := TIntCDP.ReadVecI32(Loader, TPredictorType.ptPredNULL);

      Normals := CreateSingleList(PsiCodes.Count * 3);
      for i := 0 to PsiCodes.Count -1 do
      begin
        TDeeringNormalCodec.ConvertToVector(QuantizationBits, SextantCodes[i], OctantCodes[i], ThetaCodes[i], PsiCodes[i], @Normal);

        Normals.Add(Normal.X);
        Normals.Add(Normal.Y);
        Normals.Add(Normal.Z);
      end;
    end
    else
      raise Exception.Create('TCompressedVertexNormalArray : Create'#13 +  'Negative number of quantized bits: ' + IntToStr(quantizationBits));
  end
  else
  begin
    if (QuantizationBits = 0) then
    begin
      BinaryVertexNormals := TList<TIntegerList>.Create;

      for i := 0 to NumberComponents - 1 do
        BinaryVertexNormals.Add(TIntCDP.ReadVecI32(Loader, ptPredNULL));

      Normals := CreateSingleList(BinaryVertexNormals[0].Count * 3);
      for i := 0 to BinaryVertexNormals[0].Count - 1 do
      begin
        Xi := BinaryVertexNormals[0][i];
        Yi := BinaryVertexNormals[1][i];
        Zi := BinaryVertexNormals[2][i];

        Normals.Add(PSingle(@Xi)^);
        Normals.Add(PSingle(@Yi)^);
        Normals.Add(PSingle(@Zi)^);
      end;
    end
    else
    begin
      //DeeringNormalCodes := TIntCDP.ReadVecI32(Loader, ptPredNULL);
    end;
  end;

  ReadHash := Loader.Read32;

  { free temporary memory }

  SafeFree(SextantCodes);
  SafeFree(OctantCodes);
  SafeFree(ThetaCodes);
  SafeFree(PsiCodes);
  SafeFree(Exponents);
  SafeFree(Mantissae);
  SafeFree(NormalVectorData);
  SafeFree(NormalVectorLists);
  SafeFree(BinaryVertexNormals);
  SafeFree(DeeringNormalCodes);
end;

procedure TTopologicallyCompressedVertexRecords.DecodeCompressedVertexTextureCoordinates(Loader: TCoreLoader);
var
  AExponents: TIntegerList;
  AMantissae: TIntegerList;
  CodeData: TIntegerList;
  uCodeData: TIntegerList;
  vCodeData: TIntegerList;
  UValues, VValues: TList<Single>;
  TextureCoordCount: Integer;
  NumberComponents: Integer;
  QuantizationBits: Integer;
  VertexTextureCoordExponentLists: TList<TIntegerList>;
  VertexTextureCoordMantissaeLists: TList<TIntegerList>;
  VertexTextureCodeLists: TList<TIntegerList>;
  TextureCoordCodesLists: TList<TIntegerList>;
  TextureQuantizerData: TTextureQuantizerData;
  TextureCoordinates: TList<Double>;
  i, j: Integer;
begin
  TextureCoordCount := Loader.Read32;
  NumberComponents := Loader.Read8;
  QuantizationBits := Loader.Read8;

  vertexTextureCoordExponentLists := TList<TIntegerList>.Create;
  vertexTextureCoordMantissaeLists := TList<TIntegerList>.Create;
  vertexTextureCodeLists := TList<TIntegerList>.Create;
  TextureCoordCodesLists := TList<TIntegerList>.Create;
  TextureQuantizerData := nil;
  TextureCoordinates := TList<Double>.Create;

  if (QuantizationBits = 0) then
  begin
    for i := 0 to numberComponents - 1 do
    begin
      AExponents := TIntCDP.readVecI32(Loader, TPredictorType.ptPredNULL);
      AMantissae := TIntCDP.readVecI32(Loader, TPredictorType.ptPredNULL);

      CodeData := CreateIntegerList(AExponents.Count);
      for j := 0 to AExponents.Count - 1 do
        CodeData.Add((AExponents[j] shl 23) or AMantissae[j]);

      VertexTextureCoordExponentLists.Add(AExponents);
      VertexTextureCoordMantissaeLists.Add(AMantissae);
      VertexTextureCodeLists.Add(CodeData);
    end;

    uCodeData := vertexTextureCodeLists[0];
    vCodeData := vertexTextureCodeLists[1];

    for i := 0 to uCodeData.Count - 1 do
    begin
      textureCoordinates.Add(IntAsFloat(uCodeData[i]));
      textureCoordinates.Add(IntAsFloat(vCodeData[i]));
    end;
  end
  else
  if (quantizationBits > 0) then
  begin
    TextureQuantizerData := TTextureQuantizerData.Create(Loader, NumberComponents);

    for i := 0 to numberComponents - 1 do
      textureCoordCodesLists.add(TIntCDP.ReadVecU32(Loader, TPredictorType.ptPredLag1));

    UValues := Loader.dequantize(textureCoordCodesLists[0], textureQuantizerData.UniformQuantizerDatas[0].Range, quantizationBits);
    VValues := Loader.dequantize(textureCoordCodesLists[1], textureQuantizerData.UniformQuantizerDatas[1].Range, quantizationBits);

    for i := 0 to uValues.Count - 1 do
    begin
      TextureCoordinates.add(uValues[i]);
      TextureCoordinates.add(vValues[i]);
    end;

    Loader.Read32; // Hash Value
  end
  else
    raise Exception.Create('TCompressedVertexTextureCoordinateArray : Create'#13 + 'Negative number of quantized bits: ' + IntToStr(quantizationBits));

  SafeFree(VertexTextureCoordExponentLists);
  SafeFree(VertexTextureCoordMantissaeLists);
  SafeFree(VertexTextureCodeLists);
  SafeFree(TextureCoordCodesLists);
  SafeFree(TextureQuantizerData);
  SafeFree(TextureCoordinates);
end;

//==============================================================================

constructor TTopoMeshLODData.Create(Loader: TCoreLoader);
begin
  if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if (Loader.FileVersion >= 10.0) then
    VersionNumber := Loader.Read8;

  VertexRecordsObjectID := Loader.Read32;
end;

//------------------------------------------------------------------------------

constructor TTopoMeshCompressedLODData.Create(Loader: TCoreLoader);
begin
  inherited Create(Loader);

  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if (Loader.FileVersion >= 10.0) then
    VersionNumber := Loader.Read8;
end;

//------------------------------------------------------------------------------

constructor TTopoMeshTopologicallyCompressedLODData.Create(Loader: TCoreLoader);
begin
  inherited Create(Loader);

  TopologicallyCompressedRepData := nil;

  if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if (Loader.FileVersion >= 10.0) then
    VersionNumber := Loader.Read8;

  if ((VersionNumber < 1) and (VersionNumber > 2)) then
    raise Exception.Create('Found invalid version number: ' + IntToStr(VersionNumber));

  TopologicallyCompressedRepData := TTopologicallyCompressedRepData.Create(Loader);
end;

destructor TTopoMeshTopologicallyCompressedLODData.Destroy;
begin
  if Assigned(TopologicallyCompressedRepData) then TopologicallyCompressedRepData.Free;
  inherited;
end;

//------------------------------------------------------------------------------

constructor TTopologicallyCompressedRepData.Create(Loader: TCoreLoader);
var
  i, j: Integer;
  AFaceAttrMaskList: TIntegerList;
  AList: TUInt64List;
  AText: string;
begin
  FaceDegrees := nil;
  VertexValences := nil;
  VertexGroups := nil;
  VertexFlags := nil;
  FaceAttrMasks := nil;
  SplitFaces := nil;
  SplitFacePositions := nil;
  TopologicallyCompressedVertexRecords := nil;
  AFaceAttrMaskList := nil;

  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
  begin
    FaceDegrees := TList<TIntegerList>.Create;
    for i := 0 to 8 - 1 do
      FaceDegrees.Add(TIntCDP.ReadVecI32(Loader, ptPredNULL));

    VertexValences := TIntCDP.ReadVecI32(Loader, ptPredNULL);
    VertexGroups := TIntCDP.ReadVecI32(Loader, ptPredNULL);
    VertexFlags := TIntCDP.ReadVecI32(Loader, ptPredLag1);

    { 30 Least Significant Bytes }

    FaceAttrMasks := TList<TUInt64List>.Create;
    for i := 0 to 8 - 1 do
    begin
      AFaceAttrMaskList := TIntCDP.ReadVecI32(Loader, ptPredNULL); // VecU or VecI ?
      FaceAttrMasks.Add(CreateUInt64List(AFaceAttrMaskList.Count));
      for j := 0 to AFaceAttrMaskList.Count - 1 do
        FaceAttrMasks[i].Add(AFaceAttrMaskList[j] and $3FFFFFFF);
      AFaceAttrMaskList.Free;
    end;

    { 30 Most Significant Bytes }

    AFaceAttrMaskList := TIntCDP.ReadVecI32(Loader, ptPredNULL);
    for i := 0 to AFaceAttrMaskList.Count - 1 do
      FaceAttrMasks[7][i] := FaceAttrMasks[7][i] or (UInt64(AFaceAttrMaskList[i]) shl 30);
    AFaceAttrMaskList.Free;

    { 4 Most Significant Bytes }

    AFaceAttrMaskList := TIntCDP.ReadVecI32(Loader, ptPredNULL);
    for i := 0 to AFaceAttrMaskList.Count - 1 do
      FaceAttrMasks[7][i] := FaceAttrMasks[7][i] or (UInt64(AFaceAttrMaskList[i]) shl 60);
    AFaceAttrMaskList.Free;
    AList := FaceAttrMasks[7];

    Loader.ReadVec32(HighDegreeFaceAttributeMasks);

    SplitFaces := TIntCDP.ReadVecI32(Loader, ptPredLag1);
    SplitFacePositions := TIntCDP.readVecI32(Loader, ptPredNULL);
  end
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 10.5)) then
  begin
    FaceDegrees := TList<TIntegerList>.Create;
    for i := 0 to 8 - 1 do
      FaceDegrees.Add(TIntCDP.ReadVecI32(Loader, ptPredNULL));

    VertexValences := TIntCDP.ReadVecI32(Loader, ptPredNULL);
    VertexGroups := TIntCDP.ReadVecI32(Loader, ptPredNULL);
    VertexFlags := TIntCDP.ReadVecI32(Loader, ptPredLag1);

    { 32 Least Significant Bytes }

    FaceAttrMasks := TList<TUInt64List>.Create;
    for i := 0 to 8 - 1 do
    begin
      AFaceAttrMaskList := TIntCDP.ReadVecI32(Loader, ptPredNULL);
      FaceAttrMasks.Add(CreateUInt64List(AFaceAttrMaskList.Count));
      for j := 0 to AFaceAttrMaskList.Count - 1 do
        FaceAttrMasks[i].Add(AFaceAttrMaskList[j]);
      AFaceAttrMaskList.Free;
    end;

    { 32 Most significant Bytes }

    AFaceAttrMaskList := TIntCDP.ReadVecI32(Loader, ptPredNULL);
    for i := 0 to AFaceAttrMaskList.Count - 1 do
      FaceAttrMasks[7][i] := FaceAttrMasks[7][i] or (UInt64(AFaceAttrMaskList[i]) shl 32);
    AFaceAttrMaskList.Free;

    Loader.ReadVecU32(TIntegerDynArray(HighDegreeFaceAttributeMasks));

    SplitFaces := TIntCDP.ReadVecI32(Loader, ptPredLag1);
    SplitFacePositions := TIntCDP.ReadVecI32(Loader, ptPredNULL);
  end;

  Hash := Loader.Read32;
  CheckHash;

  TopologicallyCompressedVertexRecords := TTopologicallyCompressedVertexRecords.Create(Loader);
end;

destructor TTopologicallyCompressedRepData.Destroy;
var
  i: Integer;
begin
  if Assigned(TopologicallyCompressedVertexRecords) then TopologicallyCompressedVertexRecords.Free;

  if (FaceDegrees <> nil) then
  begin
    for i := 0 to FaceDegrees.Count - 1 do
      if (FaceDegrees[i] <> nil) then
        FaceDegrees[i].Free;
    FaceDegrees.Free;
  end;

  SafeFree(VertexValences);
  SafeFree(VertexGroups);
  SafeFree(VertexFlags);

  if (FaceAttrMasks <> nil) then
  begin
    for i := 0 to FaceAttrMasks.Count - 1 do
      if (FaceAttrMasks[i] <> nil) then
        FaceAttrMasks[i].Free;
    FaceAttrMasks.Free;
  end;

  SafeFree(SplitFaces);
  SafeFree(SplitFacePositions);
  inherited;
end;

function TTopologicallyCompressedRepData.CheckHash: Boolean;
var
  AHash: Cardinal;
  vuTmp: TIntegerList;
  vuTempW: TWordList;
  i, j: Integer;
begin
  AHash := 0;

  for i := 0 to 8 - 1 do
    AHash := Hash32(FaceDegrees[i].List, FaceDegrees[i].Count, AHash);

  AHash := Hash32(VertexValences.List, VertexValences.Count, AHash);
  AHash := Hash32(VertexGroups.List, VertexGroups.Count, AHash);

  vuTempW := TWordList.Create;
  vuTempW.Capacity := VertexFlags.Count;
  for i := 0 to VertexFlags.Count - 1 do
    vuTempW.Add(Word(VertexFlags[i]));
  AHash := Hash16(vuTempW.List, vuTempW.Count * 2, AHash);
  vuTempW.Free;

  for i := 0 to 7 - 1 do
  begin
    vuTmp := CreateIntegerList(FaceAttrMasks[i].Count);
    for j := 0 to FaceAttrMasks[i].Count - 1 do
      vuTmp.Add(FaceAttrMasks[i][j] and $3FFFFFFF); // Lower 30 bits of each element
    AHash := Hash32(vuTmp.List, vuTmp.Count, AHash);
    vuTmp.Free;
  end;

  vuTmp := CreateIntegerList(FaceAttrMasks[7].Count);
  for i := 0 to FaceAttrMasks[7].Count - 1 do
    vuTmp.Add((FaceAttrMasks[7][i] shr 30) and $3FFFFFFF); // next 30 bits of each element
  AHash := Hash32(vuTmp.List, vuTmp.Count, AHash);
  vuTmp.Free;

  vuTmp := CreateIntegerList(FaceAttrMasks[7].Count);
  for i := 0 to FaceAttrMasks[7].Count - 1 do
    vuTmp.Add((FaceAttrMasks[7][i] shr 60) and $0F); // last 4 bits of each element
  AHash := Hash32(vuTmp.List, vuTmp.Count, AHash);
  vuTmp.Free;

  AHash := Hash32(HighDegreeFaceAttributeMasks, Length(HighDegreeFaceAttributeMasks), AHash);
  AHash := Hash32(SplitFaces.List, SplitFaces.Count, AHash);
  AHash := Hash32(SplitFacePositions.List, SplitFacePositions.Count, AHash);

  Result := AHash = Hash;
end;

//==============================================================================

constructor TQuantizedVertexCoordArray.Create(Loader: TCoreLoader);
var
  XVertexCoords: TIntegerList;
  YVertexCoords: TIntegerList;
  ZVertexCoords: TIntegerList;
  i: Integer;
  List1, List2, List3: TSingleList;
begin
  PointQuantizerData := TPointQuantizerData.Create(Loader);
  VertexCount := Loader.Read32;

  XVertexCoords := TIntCDP.ReadVecI32(Loader, TPredictorType.ptPredLag1);
  YVertexCoords := TIntCDP.ReadVecI32(Loader, TPredictorType.ptPredLag1);
  ZVertexCoords := TIntCDP.ReadVecI32(Loader, TPredictorType.ptPredLag1);

  List1 := TCoreLoader.Dequantize(XVertexCoords, PointQuantizerData.UFQDataX.Range, PointQuantizerData.UFQDataX.NumBits);
  List2 := TCoreLoader.Dequantize(YVertexCoords, PointQuantizerData.UFQDataY.Range, PointQuantizerData.UFQDataY.NumBits);
  List3 := TCoreLoader.Dequantize(ZVertexCoords, PointQuantizerData.UFQDataZ.Range, PointQuantizerData.UFQDataZ.NumBits);

  Vertices := CreateSingleList(VertexCount * 3);
  for i := 0 to VertexCount - 1 do
  begin
    Vertices.Add(List1[i]);
    Vertices.Add(List2[i]);
    Vertices.Add(List3[i]);
  end;

  SafeFree(XVertexCoords);
  SafeFree(YVertexCoords);
  SafeFree(ZVertexCoords);
  SafeFree(List1);
  SafeFree(List2);
  SafeFree(List3);
end;

//==============================================================================

constructor TQuantizedVertexNormalArray.Create(Loader: TCoreLoader);
var
  i: Integer;
  P: TPoint3D;
begin
  NumberOfBits := Loader.Read8;
  NormalCount := Loader.Read32;

  SextantCodes := TIntCDP.ReadVecU32(Loader, TPredictorType.ptPredLag1);
  OctantCodes := TIntCDP.ReadVecU32(Loader, TPredictorType.ptPredLag1);
  ThetaCodes := TIntCDP.ReadVecU32(Loader, TPredictorType.ptPredLag1);
  PsiCodes := TIntCDP.ReadVecU32(Loader, TPredictorType.ptPredLag1);

  Normals := CreateSingleList(NormalCount * 3);
  for i := 0 to NormalCount - 1 do
  begin
    TDeeringNormalCodec.ConvertToVector(NumberOfBits, SextantCodes[i], OctantCodes[i], ThetaCodes[i], PsiCodes[i], @P);
    Normals.Add(P.X);
    Normals.Add(P.Y);
    Normals.Add(P.Z);
  end;

  SafeFree(SextantCodes);
  SafeFree(OctantCodes);
  SafeFree(ThetaCodes);
  SafeFree(PsiCodes);
end;

//==============================================================================

constructor TQuantizedVertexColorArray.Create(Loader: TCoreLoader);
begin
  ColorQuantizerData := TPointQuantizerData.Create(Loader);
  NumberOfBits := Loader.Read8;
  NumberOfColorFloats := Loader.Read8;
  ComponentArrayFlags := Loader.Read8;

  if (ComponentArrayFlags = 0) then
    ColorCodes := TIntCDP.ReadVecU32(Loader, TPredictorType.ptPredNULL)
  else
  begin
    RedAndHueCodes := TIntCDP.ReadVecU32(Loader, TPredictorType.ptPredLag1);
    GreenAndSatCodes := TIntCDP.ReadVecU32(Loader, TPredictorType.ptPredLag1);
    BlueAndValueCodes := TIntCDP.ReadVecU32(Loader, TPredictorType.ptPredLag1);
    AlphaCodes := TIntCDP.ReadVecU32(Loader, TPredictorType.ptPredLag1);
  end;
end;

//==============================================================================

constructor TQuantizedVertexTextureCoordArray.Create(Loader: TCoreLoader);
begin
  raise Exception.Create('TQuantizedVertexTextureCoordArray : Create'#13 + 'This function is not implemented yet');
end;

//==============================================================================

constructor TVertexBasedShapeCompressedRepData.Create(Loader: TCoreLoader);
var
  AVersionNumber: Int16;
  AQuantParams: TQuantizationParameters;
begin
  Vertices := nil;
  Normals := nil;
  Colors := nil;
  TextureCoordinates := nil;
  PrimitiveListIndices := nil;

  AVersionNumber := Loader.Read16;
  if (AVersionNumber <> $01) then
    raise Exception.Create('TVertexBasedShapeCompressedRepData : Create'#13 + 'Version number is not 1');

  NormalBinding := Loader.Read8;
  TextureCoordBinding := Loader.Read8;
  ColorBinding := Loader.Read8;

  AQuantParams := TQuantizationParameters.Create(Loader);

  PrimitiveListIndices := TIntCDP.ReadVecI32(Loader, TPredictorType.ptPredStride1);

  if (AQuantParams.BitsPerVertex = 0) then
    LosslessCompressedRawVertexData(Loader)
  else
    LossyQuantizedRawVertexData(Loader);
end;

destructor TVertexBasedShapeCompressedRepData.Destroy;
begin
  SafeFree(Vertices);
  SafeFree(Normals);
  SafeFree(Colors);
  SafeFree(TextureCoordinates);
  SafeFree(PrimitiveListIndices);
  inherited;
end;

procedure TVertexBasedShapeCompressedRepData.LosslessCompressedRawVertexData(Loader: TCoreLoader);
const
  BINDING_NONE          = 0;
  BINDING_PER_VERTEX    = 1;
  BINDING_PER_FACET     = 2;
  BINDING_PER_PRIMITIVE = 3;
var
  i: Integer;
  RawVertexData: TSingleDynArray;
  CompressedDataSize: Integer;
  UncompressedDataSize: Cardinal;
begin
  UncompressedDataSize := Loader.Read32;
  CompressedDataSize := Loader.Read32;

  { Uncompressed raw data }

  if (CompressedDataSize < 0) then
  begin
    CompressedDataSize := CompressedDataSize * -1;
    SetLength(rawVertexData, compressedDataSize div 4);
    for i := 0 to Length(RawVertexData) - 1 do
      RawVertexData[i] := Loader.ReadF32;
  end
  else
  if (compressedDataSize > 0) then
  begin
    { ZLib compressed raw data }

    Loader.FetchCompressedBytes(CompressedDataSize, UncompressedDataSize);

    SetLength(RawVertexData, UncompressedDataSize div 4);
    for i := 0 to Length(RawVertexData) - 1 do
      RawVertexData[i] := Loader.ReadF32;
  end
  else
    raise Exception.Create('Invalid compressed data size: ' + IntToStr(compressedDataSize));

  Vertices := CreateSingleList(Length(RawVertexData) * 3);
  if (NormalBinding = BINDING_PER_VERTEX) then
    Normals := CreateSingleList(Length(RawVertexData) * 3);
  if (TextureCoordBinding = BINDING_PER_VERTEX) then
    TextureCoordinates := CreateSingleList(Length(RawVertexData) * 2);
  if (ColorBinding = BINDING_PER_VERTEX) then
    Colors := CreateSingleList(Length(RawVertexData) * 3);

  i := 0;
  while i <= Length(RawVertexData) - 1 do
  begin
    if (TextureCoordBinding = BINDING_PER_VERTEX) then
    begin
      TextureCoordinates.AddRange([RawVertexData[i], RawVertexData[i+1]]);
      Inc(i, 2);
    end;

    if (ColorBinding = BINDING_PER_VERTEX) then
    begin
      Colors.AddRange([RawVertexData[i], RawVertexData[i+1], RawVertexData[i+2]]);
      Inc(i, 3);
    end;

    if (NormalBinding = BINDING_PER_VERTEX) then
    begin
      Normals.AddRange([RawVertexData[i], RawVertexData[i+1], RawVertexData[i+2]]);
      Inc(i, 3);
    end;

    Vertices.AddRange([RawVertexData[i], RawVertexData[i+1], RawVertexData[i+2]]);
    Inc(i, 3);
  end;
end;

procedure TVertexBasedShapeCompressedRepData.LossyQuantizedRawVertexData(Loader: TCoreLoader);
var
  i: Integer;
  AQuantizedVertices: TQuantizedVertexCoordArray;
  AQuantizedNormals: TQuantizedVertexNormalArray;
  AQuantizedTexcoords: TQuantizedVertexTextureCoordArray;
  QuantizedVertexColorArray: TQuantizedVertexColorArray;
  VertexDataIndices: TIntegerList;
  ARawData: TSingleList;
begin
  AQuantizedVertices := nil;
  AQuantizedNormals := nil;
  AQuantizedTexcoords := nil;
  QuantizedVertexColorArray := nil;
  VertexDataIndices := nil;

  AQuantizedVertices := TQuantizedVertexCoordArray.Create(Loader);

  if (NormalBinding <> 0) then
    AQuantizedNormals := TQuantizedVertexNormalArray.Create(Loader);

  if (TextureCoordBinding <> 0) then
    AQuantizedTexcoords := TQuantizedVertexTextureCoordArray.Create(Loader);

  if (ColorBinding <> 0) then
    QuantizedVertexColorArray := TQuantizedVertexColorArray.Create(Loader);

  VertexDataIndices := TIntCDP.ReadVecI32(Loader, TPredictorType.ptPredStripIndex);

  Vertices := CreateSingleList(VertexDataIndices.Count * 3);
  for i in VertexDataIndices do
  begin
    Vertices.Add(AQuantizedVertices.Vertices[i * 3]);
    Vertices.Add(AQuantizedVertices.Vertices[i * 3 + 1]);
    Vertices.Add(AQuantizedVertices.Vertices[i * 3 + 2]);
  end;

  if (NormalBinding <> 0) then
  begin
    Normals := CreateSingleList(VertexDataIndices.Count * 3);
    for i in VertexDataIndices do
    begin
      Normals.Add(AQuantizedNormals.Normals[i * 3]);
      Normals.Add(AQuantizedNormals.Normals[i * 3 + 1]);
      Normals.Add(AQuantizedNormals.Normals[i * 3 + 2]);
    end;
  end;

  if (TextureCoordBinding <> 0) then
  begin
    TextureCoordinates := CreateSingleList(VertexDataIndices.Count * 3);
    for i in VertexDataIndices do
    begin
      Normals.Add(AQuantizedTexcoords.Textures[i * 3]);
      Normals.Add(AQuantizedTexcoords.Textures[i * 3 + 1]);
      Normals.Add(AQuantizedTexcoords.Textures[i * 3 + 2]);
    end;
  end;

  SafeFree(AQuantizedVertices);
  SafeFree(AQuantizedNormals);
  SafeFree(AQuantizedTexcoords);
  SafeFree(QuantizedVertexColorArray);
  SafeFree(VertexDataIndices);
end;

//==============================================================================

constructor TSegmentHeader.Create(Loader: TCoreLoader);
begin
  GUID := Loader.ReadGUID;
  SegmentType := TSegmentType(Loader.Read32);
  SegmentLength := Loader.Read32;
end;

//------------------------------------------------------------------------------

constructor TLogicalElementHeaderZLib.Create(Loader: TCoreLoader);
begin
  CompressionFlag := Loader.Read32;
  CompressedDataLength := Loader.Read32;
  CompresionAlogirthm := TCompressionType(Loader.Read8);
end;

//------------------------------------------------------------------------------

constructor TElementHeader.Create(Loader: TCoreLoader);
begin
  ElementLength := Loader.Read32;
  ObjectTypeID := Loader.ReadGUID;
  if (ObjectTypeID <> EndOfElementsID) then
  begin
    ObjectBaseType := TObjectBaseType(Loader.Read8);
    if (Loader.FileVersion >= 9.0) then
      ObjectId := Loader.Read32;
  end;

  if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 9.0)) then
    SkipLength := ElementLength - 17
  else
  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 11.0)) then
    SkipLength := ElementLength - 21;
end;

//------------------------------------------------------------------------------

constructor TDataSegment.Create(Loader: TCoreLoader; Offset: Int64);
var
  ElementHeaderZLib: TLogicalElementHeaderZLib;
  UncompressedSize: Cardinal;
begin
  Loader.Seek(Offset);
  SegmentHeader := TSegmentHeader.Create(Loader);

  if SupportsZLib then
  begin
    ElementHeaderZLib := TLogicalElementHeaderZLib.Create(Loader);

    if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 10.0)) then
    begin
      if (ElementHeaderZLib.CompressionFlag = 2) and (ElementHeaderZLib.CompresionAlogirthm >= caZLib) then
      begin
        UncompressedSize := 0;
        Loader.FetchCompressedBytes(ElementHeaderZLib.CompressedDataLength - 1, UncompressedSize);
      end;
    end
    else
    if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    begin
      if (ElementHeaderZLib.CompressionFlag = 3) and (ElementHeaderZLib.CompresionAlogirthm >= caLZMA) then
      begin
        UncompressedSize := 0;
        Loader.FetchCompressedBytesLZMA(ElementHeaderZLib.CompressedDataLength - 1, UncompressedSize);
      end;
    end;
  end;

  ElementHeader := TElementHeader.Create(Loader);
end;

function TDataSegment.SupportsZLib: Boolean;
begin
  case SegmentHeader.SegmentType of
    stLogSceneGraph, stBoundaryRep, stPMIData, stMetaData, stXTBoundaryRep,
    stWireFrameRep, stULP, stLWPA:
      Result := True;
    else
      Result := False;
  end;
end;

class function TDataSegment.GetClassByObjectTypeId(const AObjectTypeId: TGUID; var ABaseElementClass: TBaseElementClass): Boolean;
var
  i: Integer;
begin
  for i := 0 to ObjectTypeIDCount - 1 do
    if ObjectTypeIDs[i].GUID = AObjectTypeId then
    begin
      ABaseElementClass := ObjectTypeIDs[i].ClassType;
      Exit(True);
    end;
  ABaseElementClass := nil;
  Result := False;
end;

//==============================================================================

function TBaseElement.GetChildCount: Integer;
begin
  if ((Self.ClassType = TInstanceNodeElement) or (Self.InheritsFrom(TInstanceNodeElement))) then
    Result := 1
  else
  if Self.InheritsFrom(TGroupNodeElement) then
    Result := TGroupNodeElement(Self).ChildCount
  else
    Result := 0;
end;

function TBaseElement.GetAttributeCount: Integer;
begin
  if Self.InheritsFrom(TBaseNodeElement) then
    Result := TBaseNodeElement(Self).AttrCount
  else
    Result := 0;
end;

constructor TBaseNodeElement.Create(Loader: TCoreLoader);
var
  i: Integer;
begin
  NodeType := ntGraph;

  if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 9.0)) then
    ObjectID := Loader.Read32
  else
  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    VersionNumber := Loader.Read8;

  NodeFlags := Loader.Read32;
  AttrCount := Loader.Read32;
  SetLength(AttrObjectIDs, AttrCount);
  for i := 0 to AttrCount - 1 do
    AttrObjectIDs[i] := Loader.Read32;
end;

function TBaseElement.ToString: string;
const
  TSegmentTypeStr: array[0..21] of string = (
    '', 'LogSceneGraph', 'BoundaryRep', 'PMIData', 'MetaData', '', 'Shape', 'ShapeLOD0',
    'ShapeLOD1', 'ShapeLOD2', 'ShapeLOD3', 'ShapeLOD4', 'ShapeLOD5', 'ShapeLOD', 'ShapeLOD7',
    'ShapeLOD8', 'ShapeLOD9', 'XTBoundaryRep', 'WireFrameRep', '', 'ULP', 'LWPA');
begin
  Result := IntToStr(ObjectID) + '=' + Self.ClassName + '; ';

  Result := Result + '(';

  if Self.InheritsFrom(TGroupNodeElement) then
    Result := Result + 'ChildCount=' + IntToStr(TGroupNodeElement(Self).ChildCount) + '; '
  else
  if Self.InheritsFrom(TInstanceNodeElement) then
    Result := Result + 'ChildNodeObjectID=' + IntToStr(TInstanceNodeElement(Self).ChildNodeObjectID) + '; ';

  if Self.InheritsFrom(TBasePropertyAtomElement) then
  begin
    Result := Result + ' StateFlags=' + IntToHex(TBasePropertyAtomElement(Self).StateFlags, 8) + ', ';
    if Self.ClassType = TLateLoadedPropertyAtomElement then
      Result := Result + ' PayLoadObjectID=' + IntToStr(TLateLoadedPropertyAtomElement(Self).PayloadObjectID) + ', ';
  end;

  if (Self.ClassType = TStringPropertyAtomElement) then
    Result := Result + ' Value=' + TStringPropertyAtomElement(Self).Value + '; '
  else
  if (Self.ClassType = TIntegerPropertyAtomElement) then
    Result := Result + ' Value=' + IntToStr(TIntegerPropertyAtomElement(Self).Value) + '; '
  else
  if (Self.ClassType = TFloatingPointPropertyAtomElement) then
    Result := Result + ' Value=' + FloatToStr(TFloatingPointPropertyAtomElement(Self).Value) + '; '
  else
  if (Self.ClassType = TDatePropertyAtomElement) then
    Result := Result + ' Value=' + DateToStr(TDatePropertyAtomElement(Self).Date) + '; ';

  Result := Result + ')';
end;

//------------------------------------------------------------------------------

constructor TPartitionNodeElement.Create(Loader: TCoreLoader);
begin
  inherited Create(Loader);

  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    VersionNumber := Loader.Read8;

  PartitionFlags := Loader.Read32;
  Filename := Loader.ReadString;

  if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 10.0)) then
  begin
    if ((PartitionFlags and $01) = 0) then
      Loader.ReadVecF32(@TransformedBox, 6)
    else
      Loader.ReadVecF32(@ReservedField, 6);
  end
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    Loader.ReadVecF32(@TransformedBox, 6);

  Area := Loader.ReadF32;
  Loader.ReadVec32(@VertexCountRange, 2);
  Loader.ReadVec32(@NodeCountRange, 2);
  Loader.ReadVec32(@PolygonCountRange, 2);

  // OPTIMIZE : Unclear whether v10.0 is requiring this field or not - bad doc
  if (Loader.FileVersion < 10.0) and ((PartitionFlags and $01) <> 0) then
    Loader.ReadVecF32(@UntransformedBox, 6);
end;

//------------------------------------------------------------------------------

constructor TMetaDataNodeElement.Create(Loader: TCoreLoader);
begin
  inherited Create(Loader);

  if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    VersionNumber := Loader.Read8;
end;

//------------------------------------------------------------------------------

constructor TGroupNodeElement.Create(Loader: TCoreLoader);
var
  i: Integer;
begin
  inherited Create(Loader);

  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    VersionNumber := Loader.Read8;

  ChildCount := Loader.Read32;
  SetLength(ChildNodeObjectIDs, ChildCount);
  for i := 0 to ChildCount - 1 do
    ChildNodeObjectIDs[i] := Loader.Read32;
end;

//------------------------------------------------------------------------------

constructor TInstanceNodeElement.Create(Loader: TCoreLoader);
begin
  inherited Create(Loader);

  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    VersionNumber := Loader.Read8;
  ChildNodeObjectID := Loader.Read32;
end;

//------------------------------------------------------------------------------

constructor TPartNodeElement.Create(Loader: TCoreLoader);
begin
  inherited Create(Loader);

  if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    VersionNumber := Loader.Read8;

  ReservedField := Loader.Read32;
end;

//------------------------------------------------------------------------------

constructor TLODNodeElement.Create(Loader: TCoreLoader);
begin
  inherited Create(Loader);

  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    VersionNumber := Loader.Read8;

  if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 10.0)) then
  begin
    Loader.ReadVecF32(ReservedVector);
    ReservedField := Loader.Read32;
  end;
end;

//------------------------------------------------------------------------------

constructor TRangeLODNodeElement.Create(Loader: TCoreLoader);
begin
  inherited Create(Loader);

  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    VersionNumber := Loader.Read8;

  Loader.ReadVecF32(RangeLimits);
  Loader.ReadVecF32(@Center, 3);
end;

//------------------------------------------------------------------------------

constructor TSwitchNodeElement.Create(Loader: TCoreLoader);
begin
  inherited Create(Loader);

  if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    VersionNumber := Loader.Read8;
  SelectedChild := Loader.Read32;
end;

//------------------------------------------------------------------------------

constructor TBaseShapeNodeElement.Create(Loader: TCoreLoader);
begin
  inherited Create(Loader);

  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    VersionNumber := Loader.Read8;
  if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 10.0)) then
    Loader.ReadVecF32(@TransformedBox, 6);
  Loader.ReadVecF32(@UntransformedBox, 6);
  Area := Loader.ReadF32;
  Loader.ReadVec32(@VertexCountRange, 2);
  Loader.ReadVec32(@NodeCountRange, 2);
  Loader.ReadVec32(@PolygonCountRange, 2);
  Size := Loader.Read32;
  CompressionLevel := Loader.ReadF32;
end;

constructor TVertexShapeNodeElement.Create(Loader: TCoreLoader);
begin
  inherited Create(Loader);

  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    VersionNumber := Loader.Read8;

  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 11.0)) then
    VertexBinding := Loader.Read64;

  if ((Loader.FileVersion >= 8.0) and (LOader.FileVersion < 9.0)) then
  begin
    NormalBinding := Loader.Read32;
    TextureCoordBinding := Loader.Read32;
    ColorBinding := Loader.Read32;
  end;

  if ((Loader.FileVersion >= 8.0) and (LOader.FileVersion < 10.0)) then
    QuantizationParams := TQuantizationParameters.Create(Loader);

  if (((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) and (VersionNumber <> $01)) then
    VertexBinding := Loader.Read64;
end;

constructor TTriStripSetShapeNodeElement.Create(Loader: TCoreLoader);
begin
  inherited Create(Loader);
end;

constructor TPolylineSetShapeNodeElement.Create(Loader: TCoreLoader);
begin
  inherited Create(Loader);

  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    VersionNumber := Loader.Read8;

  AreaFactor := Loader.ReadF32;

  if (((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) and (VersionNumber = 1)) then
    VertexBindings := Loader.Read64;
end;

constructor TPointSetShapeNodeElement.Create(Loader: TCoreLoader);
begin
  inherited Create(Loader);

  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    VersionNumber := Loader.Read8;

  AreaFactor := Loader.ReadF32;

  if (((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 11.0)) and (VersionNumber = 1)) then
    VertexBindings := Loader.Read64;
end;

//------------------------------------------------------------------------------

constructor TBaseAttributeElement.Create(Loader: TCoreLoader);
begin
  NodeType := ntAttribute;

  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    VersionNumber := Loader.Read8;

  if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 9.0)) then
    ObjectID := Loader.Read32;

  StateFlags := Loader.Read8;
  FieldInhibitFlags := Loader.Read32;

  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    FieldFinalFlags := Loader.Read32;
end;

//------------------------------------------------------------------------------

constructor TMaterialAttributeElement.Create(Loader: TCoreLoader);
var
  AValue: Single;
begin
  inherited Create(Loader);

  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    VersionNumber := Loader.Read8;

  DataFlag := Loader.Read16;

  if ((Loader.FileVersion >= 9.0) or ((DataFlag and $02) = 0)) then
    Loader.ReadVecF32(@AmbientColor, 4)
  else
  begin
    AValue := Loader.ReadF32;
    AmbientColor := TVector4.Create(AValue, AValue, AValue, 1.0);
  end;

  Loader.ReadVecF32(@DiffuseColor, 4);

  if ((Loader.FileVersion >= 9.0) or ((DataFlag and $08) = 0)) then
    Loader.ReadVecF32(@SpecularColor, 4)
  else
  begin
    AValue := Loader.ReadF32;
    SpecularColor := TVector4.Create(AValue, AValue, AValue, 1.0);
  end;

  if ((Loader.FileVersion >= 9.0) or ((DataFlag and $04) = 0)) then
    Loader.ReadVecF32(@EmissionColor, 4)
  else
  begin
    AValue := Loader.ReadF32;
    EmissionColor := TVector4.Create(AValue, AValue, AValue, 1.0);
  end;

  Shineniness := Loader.ReadF32;
  if ((Loader.FileVersion >= 9.0) and (VersionNumber = 2)) or (Loader.FileVersion >= 10.0) then
    Reflectivity := Loader.ReadF32;

  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    Bumpiness := Loader.ReadF32;
end;

//------------------------------------------------------------------------------

constructor TGeometricTransformAttributeElement.Create(Loader: TCoreLoader);
var
  i: Integer;
  M: TMatrix;
  StoredValueMask: Int64;
begin
  inherited;

  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    VersionNumber := Loader.Read8;

  StoredValueMask := Loader.Read16 and $FFFF;

  for i := 15 downto 0 do
  begin
    if ((StoredValueMask and $8000) <> 0) then
    begin
      if (Loader.FileVersion >= 10.0) then
        ElementValues[i] := Loader.ReadF64
      else
        ElementValues[i] := Loader.ReadF32;
    end
    else
      ElementValues[i] := 0;
    StoredValueMask := (StoredValueMask shl 1);
  end;
end;

//------------------------------------------------------------------------------

constructor TBasePropertyAtomElement.Create(Loader: TCoreLoader);
begin
  NodeType := ntProperty;

  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    VersionNumber := Loader.Read8;

  if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 9.0)) then
    ObjectID := Loader.Read32;

  StateFlags := Loader.Read32;
end;

constructor TStringPropertyAtomElement.Create(Loader: TCoreLoader);
begin
  inherited;

  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    VersionNumber := Loader.Read8;

  Value := Loader.ReadString;
end;

constructor TIntegerPropertyAtomElement.Create(Loader: TCoreLoader);
begin
  inherited;

  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    VersionNumber := Loader.Read8;

  Value := Loader.Read32;
end;

constructor TFloatingPointPropertyAtomElement.Create(Loader: TCoreLoader);
begin
  inherited;

  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    VersionNumber := Loader.Read8;

  Value := Loader.ReadF32;
end;

constructor TObjectReferencePropertyAtomElement.Create(Loader: TCoreLoader);
begin
  inherited;

  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    VersionNumber := Loader.Read8;

  ReferenceID := Loader.Read32;
end;

constructor TDatePropertyAtomElement.Create(Loader: TCoreLoader);
var
  AYear, AMonth, ADay, AHour, AMinute, ASecond: Integer;
begin
  inherited;

  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    VersionNumber := Loader.Read8;
    
  AYear := Loader.Read16;
  AMonth := Loader.Read16;
  ADay := Loader.Read16;
  AHour := Loader.Read16;
  AMinute := Loader.Read16;
  ASecond := Loader.Read16;

  Date := EncodeDateTime(AYear, AMonth, ADay, AHour, AMinute, ASecond, 0);
end;

constructor TLateLoadedPropertyAtomElement.Create(Loader: TCoreLoader);
begin
  inherited;

  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    VersionNumber := Loader.Read8;

  SegmentId := Loader.ReadGUID;
  SegmentType := TSegmentType(Loader.Read32);

  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 11.0)) then
  begin
    PayloadObjectID := Loader.Read32;

    if (Loader.FileVersion < 10.0) then // OPTIMIZE : v10.0 doesn't seem to use the Reserved field
      Reserved := Loader.Read32;
  end;
end;

//------------------------------------------------------------------------------

constructor TPropertyTable.Create(Loader: TCoreLoader);
var
  i: Integer;
  AKey: Integer;
  AValue: Integer;
  ANodePropertyTable: PNodePropertyTable;
begin
  VersionNumber := Loader.Read16;
  NodePropertyTableCount := Loader.Read32;
  SetLength(NodePropertyTables, NodePropertyTableCount);

  for i := 0 to NodePropertyTableCount - 1 do
  begin
    NodePropertyTables[i] := TNodePropertyTableList.Create;
    NodePropertyTables[i].NodeObjectID := Loader.Read32;

    AKey := Loader.Read32;
    while (AKey <> 0) do
    begin
      AValue := Loader.Read32;
      ANodePropertyTable := New(PNodePropertyTable);
      ANodePropertyTable^ := TNodePropertyTable.Create(AKey, AValue);
      NodePropertyTables[i].Add(ANodePropertyTable);
      AKey := Loader.Read32;
    end;
  end;
end;

destructor TPropertyTable.Destroy;
var
  i: Integer;
begin
  for i := 0 to Length(NodePropertyTables) - 1 do
    NodePropertyTables[i].Free;
  SetLength(NodePropertyTables, 0);
  inherited;
end;

//------------------------------------------------------------------------------

constructor TNodePropertyTable.Create(AKey, AValue: Integer);
begin
  KeyPropertyAtomObjectID := AKey;
  ValuePropertyAtomObjectID := AValue;
end;

//------------------------------------------------------------------------------

constructor TLSGSegment.Create(Loader: TCoreLoader; Offset: Int64);
var
  ABaseElementClass: TBaseElementClass;
  AElement: TBaseElement;
  AStartPos: Cardinal;
  AParentList: TList<TGroupNodeElement>;
  AObjectID: Integer;
  ALastNode: TBaseElement;
  i: Integer;
begin
  inherited Create(Loader, Offset);

  { read node and attribute elements }

  Elements := TList<TBaseElement>.Create;
  AParentList := TList<TGroupNodeElement>.Create;
  ALastNode := nil;

  AObjectID := 0;

  while (ElementHeader.ObjectTypeID <> EndOfElementsID) do
  begin
    if GetClassByObjectTypeId(ElementHeader.ObjectTypeID, ABaseElementClass) then
    begin
      AStartPos := Loader.ByteBuffer.Position; // Remember Start Position

      AElement := ABaseElementClass.Create(Loader);
      Elements.Add(AElement);

      // Handle ObjectID increment
      // This is required since FileVersion 9.0 and above do not contain the ObjectID
      // anymore, so we have to build it from scratch

      if AElement.InheritsFrom(TBaseAttributeElement) or AElement.InheritsFrom(TBasePropertyAtomElement) then
      begin
        AElement.ObjectID := AObjectID;
        Inc(AObjectID);
      end
      else
      begin
        if (ALastNode <> nil) then
        begin
          if ALastNode.InheritsFrom(TGroupNodeElement) then
          begin
            AElement.ObjectID := TGroupNodeElement(ALastNode).ChildNodeObjectIDs[0];
            AObjectID := AElement.ObjectID + TGroupNodeElement(ALastNode).ChildCount;

            if (TGroupNodeElement(ALastNode).ChildCount > 1) then
            begin
              AParentList.Add(TGroupNodeElement(ALastNode));
              ALastNode.ChildIndex := 1;
            end;
          end
          else
          begin
            if ALastNode.InheritsFrom(TInstanceNodeElement) and (TInstanceNodeElement(ALastNode).ChildNodeObjectID >= AObjectID) then
            begin
              AElement.ObjectID := AObjectID;
              Inc(AObjectID);
            end
            else
            begin
              AElement.ObjectID := AParentList.Last.ChildNodeObjectIDs[AParentList.Last.ChildIndex];
              Inc(AParentList.Last.ChildIndex);
              if (AParentList.Last.ChildIndex >= AParentList.Last.ChildCount) then
                AParentList.Remove(AParentList.Last);
            end;
          end;
        end
        else
        begin
          AElement.ObjectID := AObjectID;
          Inc(AObjectID);
        end;

        ALastNode := AElement;
      end;

      // OPTIMIZE : Due to any reason, some Elements contain more data than the current
      // specification shows. So we have to check whether all bytes have been consumed
      // and if not, then skip the remaining bytes.

      if ((Loader.ByteBuffer.Position - AStartPos) <> ElementHeader.SkipLength) then
        Loader.Skip(ElementHeader.SkipLength - (Loader.ByteBuffer.Position - AStartPos));
    end
    else
    begin
      Loader.Skip(ElementHeader.SkipLength);
      Inc(AObjectID);
    end;

    ElementHeader := TElementHeader.Create(Loader);
  end;

  { property atom elements }

  PropertyStartIndex := AObjectID;
  ElementHeader := TElementHeader.Create(Loader);

  while (ElementHeader.ObjectTypeID <> EndOfElementsID) do
  begin
    if GetClassByObjectTypeId(ElementHeader.ObjectTypeID, ABaseElementClass) then
    begin
      if (ABaseElementClass.InheritsFrom(TBasePropertyAtomElement)) then
      begin
        AElement := ABaseElementClass.Create(Loader);
        Elements.Add(AElement);

        if (Loader.FileVersion >= 9.0) then
        begin
          AElement.ObjectID := AObjectID;
          if AElement.InheritsFrom(TLateLoadedPropertyAtomElement) then
          begin
            if (TLateLoadedPropertyAtomElement(AElement).PayloadObjectID <> 0) then
              AObjectID := TLateLoadedPropertyAtomElement(AElement).PayloadObjectID;
          end;
        end;
      end
      else
        Loader.Skip(ElementHeader.SkipLength);
    end
    else
      Loader.Skip(ElementHeader.SkipLength);

    Inc(AObjectID); // Required only for FileVersion >= 9.0

    ElementHeader := TElementHeader.Create(Loader);
  end;

  { Property Table }

  PropertyTable := TPropertyTable.Create(Loader);

  AParentList.Free;
end;

destructor TLSGSegment.Destroy;
var
  i: Integer;
begin
  for i := 0 to Elements.Count - 1 do
    Elements[i].Free;
  Elements.Free;

  PropertyTable.Free;

  inherited;
end;

function TLSGSegment.FindElement(AObjectID: Cardinal; var AElement: TBaseElement): Boolean;
var
  i: Integer;
begin
  for i := 0 to Elements.Count - 1 do
    if (Elements[i].ObjectID = AObjectID) then
    begin
      AElement := Elements[i];
      Exit(True);
    end;
  AElement := nil;
  Result := False;
end;

function TLSGSegment.GetPropertyValue(ANodeObjectID: Integer; ACode: string): Variant;
var
  i, j, k: Integer;
  AProperty: TBaseElement;
begin
  for i := 0 to Length(PropertyTable.NodePropertyTables) - 1 do
    if (PropertyTable.NodePropertyTables[i].NodeObjectID = ANodeObjectID) then
    begin
      for j := 0 to PropertyTable.NodePropertyTables[i].Count - 1 do
      begin
        if FindElement(PropertyTable.NodePropertyTables[i].Items[j].KeyPropertyAtomObjectID, AProperty) then
        begin
          if AProperty.ClassType = TStringPropertyAtomElement then
          begin
            if TStringPropertyAtomElement(AProperty).Value = ACode then
            begin
              AProperty := Elements[PropertyTable.NodePropertyTables[i].Items[j].ValuePropertyAtomObjectID];
              if (AProperty.ClassType = TStringPropertyAtomElement) then
              begin
                Result := TStringPropertyAtomElement(AProperty).Value;
                Break;
              end;
            end;
          end;
        end;
      end;
    end;
end;

function TLSGSegment.GetLateLoadedSegmentID(ANodeObjectID: Integer; ACode: string; var AGUID: TGUID): Boolean;
var
  i, j: Integer;
  AProperty: TBaseElement;
begin
  for i := 0 to Length(PropertyTable.NodePropertyTables) - 1 do
    if (PropertyTable.NodePropertyTables[i].NodeObjectID = ANodeObjectID) then
    begin
      for j := 0 to PropertyTable.NodePropertyTables[i].Count - 1 do
      begin
        if FindElement(PropertyTable.NodePropertyTables[i].Items[j].KeyPropertyAtomObjectID, AProperty) then
          if (AProperty.ClassType = TStringPropertyAtomElement) and (TStringPropertyAtomElement(AProperty).Value = ACode) then
          begin
            if FindElement(PropertyTable.NodePropertyTables[i].Items[j].ValuePropertyAtomObjectID, AProperty) then
              if (AProperty.ClassType = TLateLoadedPropertyAtomElement) then
              begin
                AGUID := TLateLoadedPropertyAtomElement(AProperty).SegmentID;
                Exit(True);
              end;
          end;
        end;
    end;
  AGUID := TGUID.Empty;
end;

//==============================================================================

constructor TBaseShapeLODElement.Create(Loader: TCoreLoader);
begin
  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if (Loader.FileVersion >= 10.0) then
    VersionNumber := Loader.Read8;
end;

//------------------------------------------------------------------------------

constructor TVertexShapeLODElement.Create(Loader: TCoreLoader);
var
  AElementHeader: TElementHeader;
begin
  inherited Create(Loader);

  TopoMeshCompressedLODData := nil;
  TopoMeshTopologicallyCompressedLODData := nil;

  if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if (Loader.FileVersion >= 10.0) then
    VersionNumber := Loader.Read8;

  if (VersionNumber <> $01) then
    raise Exception.Create('TVertexShapeLODData : Create()'#13 + 'Version not supported');

  if (Loader.FileVersion >= 9.0) then
  begin
    VertexBindings := Loader.Read64;

    if (Loader.FileVersion >= 10.0) then
      AElementHeader := TElementHeader.Create(Loader);

    if (ClassType = TTriStripSetShapeLODElement) then
      TopoMeshTopologicallyCompressedLODData := TTopoMeshTopologicallyCompressedLODData.Create(Loader)
    else
    if (ClassParent = TPolyLineSetShapeLODElement) then
      TopoMeshCompressedLODData := TTopoMeshCompressedLODData.Create(Loader);
  end
  else
  begin
    VertexBindings := Loader.Read32 and $FFFF;
    QuantizationParameters := TQuantizationParameters.Create(Loader);
  end;
end;

destructor TVertexShapeLODElement.Destroy;
begin
  SafeFree(TopoMeshCompressedLODData);
  SafeFree(TopoMeshTopologicallyCompressedLODData);
  inherited;
end;

//------------------------------------------------------------------------------

constructor TTriStripSetShapeLODElement.Create(Loader: TCoreLoader);
begin
  inherited Create(Loader);

  VtexBasedShapeComprRepData := nil;

  if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 10.0)) then
    VersionNumber := Loader.Read16
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    VersionNumber := Loader.Read8;

  if (VersionNumber <> $01) then
    raise Exception.Create('TTriStripSetShapeLODElement.Create()'#13 + 'VersionNumber is not $01');

  if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 9.0)) then
    VtexBasedShapeComprRepData := TVertexBasedShapeCompressedRepData.Create(Loader);
end;

destructor TTriStripSetShapeLODElement.Destroy;
begin
  SafeFree(VtexBasedShapeComprRepData);
  inherited;
end;

//------------------------------------------------------------------------------

constructor TPolyLineSetShapeLODElement.Create(Loader: TCoreLoader);
begin
  inherited Create(Loader);

  VersionNumber := Loader.Read16;

  if VersionNumber <> $0001 then
    raise Exception.Create('TPolyLineSetShapeLODElement:'#13#10 +
      'VersionNumber is not $0001');
end;

destructor TPolyLineSetShapeLODElement.Destroy;
begin
  inherited;
end;

//------------------------------------------------------------------------------

constructor TShapeLODSegment.Create(Loader: TCoreLoader; Offset: Int64);
var
  ABaseElementClass: TBaseElementClass;
  ANodeType: TNodeType;
begin
  inherited Create(Loader, Offset);
  Element := nil;

  if GetClassByObjectTypeId(ElementHeader.ObjectTypeID, ABaseElementClass) then
  begin
    if ABaseElementClass = TTriStripSetShapeLODElement then
      Element := ABaseElementClass.Create(Loader) as TBaseShapeLODElement
    else
      ShowMessage('Unsupported Class');
  end;
end;

destructor TShapeLODSegment.Destroy;
begin
  SafeFree(Element);
  inherited;
end;

//==============================================================================

constructor TTOCEntry.Create(Loader: TCoreLoader);
begin
  SegmentID := Loader.ReadGUID;
  if Loader.FileVersion < 10.0 then
    SegmentOffset := Loader.Read32
  else
    SegmentOffset := Loader.Read64;
  SegmentLength := Loader.Read32;
  SegmentAttributes := Loader.Read32;
end;

function TTOCEntry.GetSegmentType: TSegmentType;
var
  i: Integer;
begin
  i := (SegmentAttributes AND $FF000000) shr 24;
  Result := TSegmentType(i)
end;

//------------------------------------------------------------------------------

constructor TFileHeader.Create(Loader: TCoreLoader; var AVersion: Single);
var
  VersionPos: Integer;
  VersionStr: string;
  VersionLen: Integer;
begin
  Loader.FetchBytes(80); // Preload JT Identification into the buffer

  { Version }

  SetString(VersionStr, PAnsiChar(@Loader.ByteBuffer.Buffer[0]), 16);

  VersionPos := Pos('Version ', VersionStr) + Length('Version ');
  VersionLen := Pos(' ', VersionStr, VersionPos) - VersionPos;
  VersionStr := MidStr(VersionStr, VersionPos, VersionLen);

  if FormatSettings.DecimalSeparator = ',' then
    VersionStr := StringReplace(VersionStr, '.', ',', []);

  AVersion := StrToFloat(VersionStr);

  if (CompareMem(@Loader.ByteBuffer.Buffer[75], @JTValidityBytes[0], 5) = False) then
  begin
    if (CompareMem(@Loader.ByteBuffer.Buffer[0], @JTValidityText[0], 7) = False) then
      raise Exception.Create('Kein gültiges JT-File. Der Vorgang wird beendet.')
  end;

  Loader.ByteBuffer.Position := Loader.ByteBuffer.Position + 80;
  if (AVersion < 8.0) or (AVersion >= 11.0) then
    raise Exception.Create('Version ' + FloatToStrF(AVersion, ffFixed, 2, 1) + ' wird nicht unterstützt.');

  ByteOrder := Loader.Read8;  // 0 = Least Significant byte first (Delphi-Default) | 1 = Most Significant byte first (Swapping required)
  if ByteOrder = 0 then
    Loader.Endian := boLittleEndian
  else
    Loader.Endian := boBigEndian;

  EmptyField := Loader.Read32;

  if (AVersion < 10.0) then
    TOCOffset := Loader.Read32 // Defines the byte offset from the top of the file to the start of the TOC Segment
  else
    TOCOffset := Loader.Read64;

  LSGSegmentID := Loader.ReadGUID;
  Loader.Seek(TOCOffset); // ignore LSG Segment ID
end;

end.
