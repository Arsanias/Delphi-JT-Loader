// Copyright (c) 2021 Arsanias
// Distributed under the MIT software license, see the accompanying
// file LICENSE or http://www.opensource.org/licenses/mit-license.php.

unit
  JTMesh;

interface

uses
  System.SysUtils, System.Types, System.StrUtils, System.Variants, System.UITypes, System.ZLib,
  System.Classes, System.Math,
  Vcl.Dialogs,
  Generics.Defaults, Generics.Collections,
  Core.Types, Core.Utils, Core.ByteReader, Core.Loader,
  JTFormat;

type
  TBitVector = class(TList<Cardinal>)
  public
    constructor Create;
    function TestBit(ABitPos: Integer): Boolean;
    procedure SetBit(ABitPos: Integer);
  end;

  PVertexEntry = ^TVertexEntry;
  TVertexEntry = record
    Valence: Integer;
    Flags: Integer;
    VertexFaceIndex: Integer;
    GroupIndex: Integer;
    constructor Create(cVal, iVFI, uFlags, iVGrp: Integer);
    class function Allocate: PVertexEntry; static;
  end;

  PFaceEntry = ^TFaceEntry;
  TFaceEntry = record
    FaceDegree: Integer;
    EmptyDegree: Integer;
    Flags: Integer;
    FaceVertexIndex: Integer;
    FaceAttrIndex: Integer;
    AttrCount: Integer;
    AttrMask: Int64; // Degree-ring attr mask as a UInt64
    constructor Create(InitParams: Boolean);
    class function Allocate: PFaceEntry; static;
  end;

  TDualMesh = class // V9.5-337
  private
    FVertexEntries: TList<PVertexEntry>;
    FFaceEntries: TList<PFaceEntry>;
    VertexFaceIndices: TIntegerList;
    FaceVertexIndices: TIntegerList;
    FaceAttrIndices: TIntegerList;
    function AddFaceEntry(AFaceDegree, AAttrCount: Integer; AAttrMask: Int64; Flags: Integer): PFaceEntry; // newFace()
    function AddVertexEntry(AValence: Integer): PVertexEntry; // newVtx()
    function FindVertexFaceSlot(AVertexIndex, AFaceIndex: Integer): Integer; // findFaceSlot()
    function FindFaceVertexSlot(AFaceIndex, AVertexIndex: Integer): Integer; // findVtxSlot()
    function GetFaceVertex(AFaceIndex, AFaceVertexSlot: Integer): Integer;
    function GetFaceAttribute(AFaceIndex, AAttrSlot: Integer): Integer;
    function GetFaceAttributeEx(AVertexIndex, AFaceIndex: Integer): Integer;
    function GetVertexFaceIndex(AVertexIndex, AVertexFaceSlot: Integer): Integer;
    procedure SetFaceVertex(AFaceIndex, AFaceVertexSlot, AVertexIndex: Integer); // setFaceVtx()
    procedure SetFaceAttribute(AFaceIndex, AFaceAttrSlot, AFaceAttr: Integer); //
    procedure SetVertexFace(AVertexIndex, AVertexFaceSlot, AFaceIndex: Integer); // setVtxFace()
    function IsValidFace(iFace: Integer): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear; // clear()
    property FaceEntries: TList<PFaceEntry> read FFaceEntries;
    property VertexEntries: TList<PVertexEntry> read FVertexEntries;
  end;

  TMeshCodeDriver = class
  protected
    FTopoCompRepData: TTopologicallyCompressedRepData;
    FaceDegreeIndices: array[0..7] of Integer;
    VertexFlagIndex: Integer;
    VertexGroupIndex: Integer;
    VertexValenceIndex: Integer;
    FaceAttrMaskIndices: array[0..7] of Integer;
    HDFaceAttrMaskIndex: Integer;
    SplitFaceIndex: Integer;
    SplitFacePosIndex: Integer;
    function GetNextFaceDegree(AContextIndex: Integer): Integer; // nextDegSymbol()
    function GetNextVertexFlag: Word; // nextVtxFlagSymbol()
    function GetNextVertexGroup: Integer; // nextFGrpSymbol()
    function GetNextVertexValence: Integer; // nextValSymbol()
    function GetNextAttrMask(AContextIndex: Integer): Int64; // nextAttrMaskSymbol()
    function GetNextSplitFace: Integer;
    function GetNextSplitFacePos: Integer;
    procedure Validate;
  public
    property TopoCompRepData: TTopologicallyCompressedRepData read FTopoCompRepData;
  end;

  TMeshDecoder = class(TMeshCodeDriver)
  private
    FDualMesh: TDualMesh;
    ActiveFaces: TIntegerList;
    RemovedActiveFaces: TBitVector;
    FaceAttrCounter: Integer;
    FVertexIndices: TIntegerList;
    FNormalIndices: TIntegerList;
    function GetFaceContext(AVertexIndex: Integer): Integer; // faceCntxt()
    function CreateFace(AVertexIndex: Integer): Integer; // ioFace()
    function CreateVertex: Integer; // ioVtx()
    function ActivateFace(AVertexIndex, AVertexFaceSlot: Integer): Integer; // activateF()
    function ActivateVertex(AFaceIndex, AFaceVertexSlot: Integer): Integer; // activateV()
    procedure AddVertexToFace(AVertexIndex, AVertexFaceSlot, AFaceIndex, AFaceVertexSlot: Integer); // addVtxToFace()
    procedure CompleteFace(AFaceIndex: Integer); // completeF()
    procedure CompleteVertex(AVertexIndex, AFaceVertexSlot: Integer); // completeV()
    function GetFaceBySplitOffset: Integer; // ioSplitFace()
    function GetNextActiveFace: Integer; // nextActiveFace()
    function RunComponent: Boolean;
    procedure Run; // run()
    procedure Clear;
  public
    constructor Create(ATopoCompRepData: TTopologicallyCompressedRepData);
    destructor Destroy; override;
    function Decode: Boolean; // V9.5-344
    property VertexIndices: TIntegerList read FVertexIndices;
    property NormalIndices: TIntegerList read FNormalIndices;
    property DualMesh: TDualMesh read FDualMesh;
  end;

implementation

//==============================================================================

constructor TBitVector.Create;
begin
  inherited Create;
  Capacity := 5000;
end;

function TBitVector.TestBit(ABitPos: Integer): Boolean;
var
  AListIndex: Integer;
begin
  AListIndex := ABitPos shr 5; // div 32
  if (AListIndex < Count) then
    Result := (0 <> (Items[AListIndex] and (1 shl (ABitPos mod 32))))
  else
    Result := False;
end;

procedure TBitVector.SetBit(ABitPos: Integer);
var
  AListIndex: Integer;
begin
  AListIndex := ABitPos shr 5; // div 32
  if (AListIndex >= Count) then
    while (Count < (AListIndex + 1)) do
      Add(0);

  Items[AListIndex] := Items[AListIndex] or (1 shl ((ABitPos mod 32)));
end;

//==============================================================================

constructor TVertexEntry.Create(cVal, iVFI, uFlags, iVGrp: Integer);
begin
  Self.Valence := cVal;
  Self.VertexFaceIndex := iVFI;
  Self.Flags := uFlags;
  Self.GroupIndex := iVGrp;
end;

class function TVertexEntry.Allocate: PVertexEntry;
begin
  Result := New(PVertexEntry);
  Result^ := TVertexEntry.Create(-1, -1, -1, -1);
end;

//==============================================================================

constructor TFaceEntry.Create(InitParams: Boolean);
begin
  if InitParams then
  begin
    FaceDegree := 0;
    EmptyDegree := 0;
    FaceVertexIndex := -1;
    FaceAttrIndex := -1;
    AttrCount := 0;
    Flags := 0;
    AttrMask := 0;
  end;
end;

class function TFaceEntry.Allocate: PFaceEntry;
begin
  Result := New(PFaceEntry);
  Result^ := TFaceEntry.Create(True);
end;

//==============================================================================

constructor TDualMesh.Create;
const
  DEFAULT_VERTEX_CAPACITY = 5000;
begin
  FVertexEntries := TList<PVertexEntry>.Create;
  FVertexEntries.Capacity := DEFAULT_VERTEX_CAPACITY;
  FFaceEntries := TList<PFaceEntry>.Create;
  FFaceEntries.Capacity := DEFAULT_VERTEX_CAPACITY;
  VertexFaceIndices := CreateIntegerList(DEFAULT_VERTEX_CAPACITY);
  FaceVertexIndices := CreateIntegerList(DEFAULT_VERTEX_CAPACITY);
  FaceAttrIndices := CreateIntegerList(DEFAULT_VERTEX_CAPACITY);
end;

destructor TDualMesh.Destroy;
var
  i: Integer;
begin
  for i := 0 to VertexEntries.Count do
    Dispose(VertexEntries[i]);
  VertexEntries.Free;

  FaceEntries.Free;
  VertexFaceIndices.Free;
  FaceVertexIndices.Free;
  FaceAttrIndices.Free;

  inherited;
end;

procedure TDualMesh.Clear;
begin
	VertexEntries.Clear;
	FaceEntries.Clear;
	VertexFaceIndices.Clear;
	FaceVertexIndices.Clear;
	FaceAttrIndices.Clear;
end;

function TDualMesh.GetVertexFaceIndex(AVertexIndex, AVertexFaceSlot: Integer): Integer;
var
  AVertexEntry: PVertexEntry;
begin
  AVertexEntry := VertexEntries[AVertexIndex];
  Result := VertexFaceIndices[AVertexEntry.VertexFaceIndex + AVertexFaceSlot];
end;

function TDualMesh.FindVertexFaceSlot(AVertexIndex, AFaceIndex: Integer): Integer;
var
  AVertexEntry: PVertexEntry;
  i: Integer;
begin
  AVertexEntry := VertexEntries[AVertexIndex];
  for i := 0 to AVertexEntry.Valence - 1 do
    if (VertexFaceIndices[AVertexEntry.VertexFaceIndex + i] = AFaceIndex) then
      Exit(i);
  Result := -1;
end;

function TDualMesh.FindFaceVertexSlot(AFaceIndex, AVertexIndex: Integer): Integer;
var
  AFaceEntry: PFaceEntry;
  i: Integer;
begin
  AFaceEntry := FaceEntries[AFaceIndex];

  for i := 0 to AFaceEntry.FaceDegree - 1 do
    if (FaceVertexIndices[AFaceEntry.FaceVertexIndex + i] = AVertexIndex) then
       Exit(i);
  Result := -1;
end;

function TDualMesh.GetFaceVertex(AFaceIndex, AFaceVertexSlot: Integer): Integer;
begin
  Result := FaceVertexIndices[FaceEntries[AFaceIndex].FaceVertexIndex + AFaceVertexSlot];
end;

function TDualMesh.GetFaceAttributeEx(AVertexIndex, AFaceIndex: Integer): Integer;
var
  AFaceEntry: PFaceEntry;
  AAttrSlot, AFaceVertexSlot, iSlot: Integer;
begin
  AFaceEntry := FaceEntries[AFaceIndex];
  if (AFaceEntry.AttrCount <= 0) then Exit(-1);

  AAttrSlot := -1;
  for AFaceVertexSlot := 0 to AFaceEntry.FaceDegree - 1 do
  begin
    iSlot := AFaceVertexSlot;
    if ((AFaceEntry.AttrMask and (1 shl iSlot)) <> 0) then
      Inc(AAttrSlot);

    while (AAttrSlot < 0) do
      AAttrSlot := AAttrSlot + AFaceEntry.AttrCount;

    if (FaceVertexIndices[AFaceEntry.FaceVertexIndex + AFaceVertexSlot] = AVertexIndex) then
      Exit(FaceAttrIndices[AFaceEntry.FaceAttrIndex + (AAttrSlot mod AFaceEntry.AttrCount)]);
  end;

  Result := -1;
end;

function TDualMesh.GetFaceAttribute(AFaceIndex, AAttrSlot: Integer): Integer;
var
  AFaceEntry: PFaceEntry;
begin
  if ((AFaceIndex >= 0) and (AFaceIndex < FaceEntries.Count)) then
  begin
    AFaceEntry := FaceEntries[AFaceIndex];
    if ((AAttrSlot >= 0) and (AAttrSlot < AFaceEntry.FaceDegree)) then
      Result := FaceAttrIndices[AFaceEntry.FaceAttrIndex + AAttrSlot];
  end
  else
    Result := 0;
end;

function TDualMesh.IsValidFace(iFace: Integer): Boolean;
begin
  if ((iFace >= 0) and (iFace < FaceEntries.Count)) then
    Result := (FaceEntries[iFace].FaceDegree <> 0)
  else
    Result := False;
end;

function TDualMesh.AddFaceEntry(AFaceDegree, AAttrCount: Integer; AAttrMask: Int64; Flags: Integer): PFaceEntry;
var
  i: Integer;
begin
  Result := TFaceEntry.Allocate;
  FaceEntries.Add(Result);

  Result.FaceDegree := AFaceDegree;
  Result.EmptyDegree := AFaceDegree;
  Result.Flags := Flags;
  Result.AttrCount := AAttrCount;
  Result.AttrMask := AAttrMask;
  Result.FaceVertexIndex := FaceVertexIndices.Count;
  Result.FaceAttrIndex := FaceAttrIndices.Count;

  while ((Result.FaceVertexIndex + AFaceDegree) > FaceVertexIndices.Count) do // verify
    FaceVertexIndices.Add(0);

  while ((Result.FaceAttrIndex + AAttrCount) > FaceAttrIndices.Count) do
    FaceAttrIndices.Add(0);

  for i := Result.FaceVertexIndex to (Result.FaceVertexIndex + AFaceDegree) - 1 do
    FaceVertexIndices[i] :=  -1;

  for i := Result.FaceAttrIndex to (Result.FaceAttrIndex + AAttrCount) - 1 do
    FaceAttrIndices[i]:= -1;
end;

function TDualMesh.AddVertexEntry(AValence: Integer): PVertexEntry;
var
  i: Integer;
begin
  Result := TVertexEntry.Allocate;
  VertexEntries.Add(Result);

  Result.Valence := AValence;
  Result.VertexFaceIndex := VertexFaceIndices.Count;

  while ((Result.VertexFaceIndex + AValence) > VertexFaceIndices.Count) do //_viVtxFaceIndices.verify
    VertexFaceIndices.Add(0);

  for i := Result.VertexFaceIndex to (Result.VertexFaceIndex + AValence) - 1 do
    VertexFaceIndices[i] := -1;
end;

procedure TDualMesh.SetFaceAttribute(AFaceIndex, AFaceAttrSlot, AFaceAttr: Integer);
var
  AFaceEntry: PFaceEntry;
begin
  AFaceEntry := FaceEntries[AFaceIndex];
  FaceAttrIndices[AFaceEntry.FaceAttrIndex + AFaceAttrSlot] := AFaceAttr;
end;

procedure TDualMesh.SetVertexFace(AVertexIndex, AVertexFaceSlot, AFaceIndex: Integer);
var
  AVertexEntry: PVertexEntry;
begin
  AVertexEntry := VertexEntries[AVertexIndex];
  VertexFaceIndices[AVertexEntry.VertexFaceIndex + AVertexFaceSlot] := AFaceIndex;
end;

// Attaches Vertex to a Face at given Slot. If the Slot was empty, then it decreases the
// Empty-Face-Degree counter to distinguish new Faces from completed

procedure TDualMesh.SetFaceVertex(AFaceIndex, AFaceVertexSlot, AVertexIndex: Integer);
var
  AFaceEntry: PFaceEntry;
begin
  AFaceEntry := FaceEntries[AFaceIndex];

  if (FaceVertexIndices[AFaceEntry.FaceVertexIndex + AFaceVertexSlot] <> AVertexIndex) then
  begin
    FaceVertexIndices[AFaceEntry.FaceVertexIndex + AFaceVertexSlot] := AVertexIndex;
    AFaceEntry.EmptyDegree := AFaceEntry.EmptyDegree - 1;
  end;
end;

//==============================================================================

function TMeshCodeDriver.GetNextFaceDegree(AContextIndex: Integer): Integer;
begin
  if (FaceDegreeIndices[AContextIndex] < TopoCompRepData.FaceDegrees[AContextIndex].Count) then
  begin
    Result := TopoCompRepData.FaceDegrees[AContextIndex][FaceDegreeIndices[AContextIndex]];
    Inc(FaceDegreeIndices[AContextIndex]);
  end
  else
    Result := -1;
end;

function TMeshCodeDriver.GetNextAttrMask(AContextIndex: Integer): Int64;
begin
  if (FaceAttrMaskIndices[AContextIndex] < TopoCompRepData.FaceAttrMasks[AContextIndex].Count) then
  begin
    Result := TopoCompRepData.FaceAttrMasks[AContextIndex][FaceAttrMaskIndices[AContextIndex]]; // All 64 Bits
    Inc(FaceAttrMaskIndices[AContextIndex]);
  end
  else
    Result := 0;
end;

function TMeshCodeDriver.GetNextSplitFace: Integer;
begin
  if (SplitFaceIndex < TopoCompRepData.SplitFaces.Count) then
  begin
    Result := TopoCompRepData.SplitFaces[SplitFaceIndex];
    Inc(SplitFaceIndex);
  end
  else
    Result := -1;
end;

function TMeshCodeDriver.GetNextSplitFacePos: Integer;
begin
  if (SplitFacePosIndex < TopoCompRepData.SplitFacePositions.Count) then
  begin
    Result := TopoCompRepData.SplitFacePositions[SplitFacePosIndex];
    Inc(SplitFacePosIndex);
  end
  else
    Result := -1;
end;

function TMeshCodeDriver.GetNextVertexValence: Integer;
begin
  if (VertexValenceIndex < TopoCompRepData.VertexValences.Count) then
  begin
    Result := TopoCompRepData.VertexValences[VertexValenceIndex];
    Inc(VertexValenceIndex);
  end
  else
    Result := -1;
end;

function TMeshCodeDriver.GetNextVertexGroup: Integer;
begin
  if (VertexGroupIndex < TopoCompRepData.VertexGroups.Count) then
  begin
    Result := TopoCompRepData.VertexGroups[VertexGroupIndex];
    Inc(VertexGroupIndex);
  end
  else
    Result := -1;
end;

function TMeshCodeDriver.GetNextVertexFlag: Word;
begin
  if (VertexFlagIndex < TopoCompRepData.VertexFlags.Count) then
  begin
    Result := TopoCompRepData.VertexFlags[VertexFlagIndex];
    Inc(VertexFlagIndex);
  end
  else
    Result := 0;
end;

procedure TMeshCodeDriver.Validate;
var
  AFailed: Boolean;
  i: Integer;
begin
  AFailed := False;

  for i := 0 to 8 - 1 do
    if ((FaceDegreeIndices[i] <> TopoCompRepData.FaceDegrees[i].Count) or
      (FaceAttrMaskIndices[i] <> TopoCompRepData.FaceAttrMasks[i].Count)) then
      raise Exception.Create('TMeshCodeDriver:'#13#10 +
        'Not all symbols have been consumed!');

  AFailed := AFailed or (VertexValenceIndex <> TopoCompRepData.VertexValences.Count);
  AFailed := AFailed or (VertexGroupIndex <> TopoCompRepData.VertexGroups.Count);
  AFailed := AFailed or (VertexFlagIndex <> TopoCompRepData.VertexFlags.Count);
  AFailed := AFailed or (HDFaceAttrMaskIndex <> Length(TopoCompRepData.HighDegreeFaceAttributeMasks));
  AFailed := AFailed or (SplitFaceIndex <> TopoCompRepData.SplitFaces.Count);
  AFailed := AFailed or (SplitFacePosIndex <> TopoCompRepData.SplitFacePositions.Count);

  if (AFailed) then
    raise Exception.Create('TMeshCodeDriver:'#13#10 +
      'Not all symbols have been consumed!');
end;

//==============================================================================

constructor TMeshDecoder.Create(ATopoCompRepData: TTopologicallyCompressedRepData);
begin
  FDualMesh := nil;
  FVertexIndices := nil;
  FNormalIndices := nil;
  FTopoCompRepData := ATopoCompRepData;
  ActiveFaces := TIntegerList.Create;
  RemovedActiveFaces := TBitVector.Create;
end;

destructor TMeshDecoder.Destroy;
begin
  ActiveFaces.Free;
  RemovedActiveFaces.Free;
  inherited;
end;

procedure TMeshDecoder.Clear;
var
  i: Integer;
begin
	ActiveFaces.Clear;
  RemovedActiveFaces.Clear;
  FaceAttrCounter := 0;

  { reset counters }

  for i := 0 to 7 do
  begin
    FaceDegreeIndices[i] := 0;
    FaceAttrMaskIndices[i] := 0;
  end;
  VertexValenceIndex := 0;
  VertexGroupIndex := 0;
  VertexFlagIndex := 0;
  HDFaceAttrMaskIndex := 0;
  SplitFaceIndex := 0;
  SplitFacePosIndex := 0;
end;

procedure TMeshDecoder.Run;
var
  AFoundComponent: Boolean;
begin
  DualMesh.Clear;
  Clear;

  AFoundComponent := True;
  while (AFoundComponent) do
    AFoundComponent := RunComponent;
end;

function TMeshDecoder.Decode: Boolean;
var
  i, j, k: Integer;
  AFaceIndex, iAttr: Integer;
  AVertexEntry: PVertexEntry;
begin
  { decode data }

  FDualMesh := TDualMesh.Create;
  Clear;

  Run;
  Validate;

  { create mesh }

  FVertexIndices := CreateIntegerList(DualMesh.VertexEntries.Count);
  FNormalIndices := CreateIntegerList(DualMesh.VertexEntries.Count);

  for i := 0 to DualMesh.VertexEntries.Count - 1 do
  begin
    AVertexEntry := DualMesh.VertexEntries[i];

    if (AVertexEntry.GroupIndex >= 0) then
      for j := 0 to AVertexEntry.Valence - 1 do
      begin
        AFaceIndex := DualMesh.VertexFaceIndices[AVertexEntry.VertexFaceIndex + j];
        VertexIndices.Add(AFaceIndex);

        iAttr := DualMesh.GetFaceAttributeEx(i, AFaceIndex);
        NormalIndices.Add(iAttr);
      end;
  end;

  Result := True;
end;

// Computes a "compression context" from 0 to 7 inclusive for faces on vertex
// iVtx. The context is based on the vertex's valence, and the total _known_
// degree of already-coded faces on the vertex at the time of the call.

function TMeshDecoder.GetFaceContext(AVertexIndex: Integer): Integer;
var
  AValence, KnownFaceCount, KnownTotalDegrees, AFaceIndex: Integer;
  i: Integer;
begin
  KnownFaceCount := 0;
  KnownTotalDegrees := 0;

  { calculate total FaceCount and FaceDegrees }

  AValence := DualMesh.VertexEntries[AVertexIndex].Valence;

  for i := 0 to AValence - 1 do
  begin
    AFaceIndex := DualMesh.GetVertexFaceIndex(AVertexIndex, i);

    if (not DualMesh.IsValidFace(AFaceIndex)) then
      Continue;
    Inc(KnownFaceCount);
    KnownTotalDegrees := KnownTotalDegrees + DualMesh.FaceEntries[AFaceIndex].FaceDegree;
  end;

  case AValence of
    3: // Regular tristrip-like meshes tend to have degree 6 faces (2 * 3)
      if (KnownTotalDegrees < KnownFaceCount * 6) then
        Result := 0
      else
      if (KnownTotalDegrees = KnownFaceCount * 6) then
        Result := 1
      else
        Result := 2;
    4: // Regular quadstrip-like meshes tend to have degree 4 faces
      if (KnownTotalDegrees < KnownFaceCount * 4) then
        Result := 3
      else
      if (KnownTotalDegrees = KnownFaceCount * 4) then
        Result := 4
      else
        Result := 5;
    5: // Pentagons are all lumped into context 6
      Result := 6
    else // All other polygons are lumped into context 7
      Result := 7;
  end;
end;

function TMeshDecoder.CreateFace(AVertexIndex: Integer): Integer;
var
  AFaceDegree: Integer;
  AFaceAttrCount, AFaceAttrSlot: Integer;
  AMask, AFaceAttrMask: Int64;
  AFaceContext: Integer;
begin
  AFaceContext := GetFaceContext(AVertexIndex);

  AFaceDegree := GetNextFaceDegree(AFaceContext);
  if (AFaceDegree > 64) then
    raise Exception.Create('TMeshDecoder.CreateFace()#13' +
      'FaceDegree > 64 Bit . This is not implemented yet.');

  if (AFaceDegree > 0) then
  begin
    Result := DualMesh.FaceEntries.Count;

    { count the number of attribute bits }

    AFaceAttrCount := 0;
    AFaceAttrMask := GetNextAttrMask(Min(7, Max(0, AFaceDegree - 2)));

    AMask := AFaceAttrMask;
    while (AMask > 0) do
    begin
      AFaceAttrCount := AFaceAttrCount + (AMask and $01);
      AMask := AMask shr 1;
    end;

    DualMesh.AddFaceEntry(AFaceDegree, AFaceAttrCount, AFaceAttrMask, 0);

    for AFaceAttrSlot := 0 to AFaceAttrCount - 1 do
    begin
      DualMesh.SetFaceAttribute(Result, AFaceAttrSlot, FaceAttrCounter);
      Inc(FaceAttrCounter);
    end;
  end
  else
    Result := -1;
end;

function TMeshDecoder.CreateVertex: Integer;
var
  AVertexValence: Integer;
  AVertexEntry: PVertexEntry;
begin
  AVertexValence := GetNextVertexValence;
  if (AVertexValence > -1) then
  begin
    AVertexEntry := DualMesh.AddVertexEntry(AVertexValence);
    AVertexEntry.GroupIndex := GetNextVertexGroup;
    AVertexEntry.Flags := GetNextVertexFlag;

    Result := DualMesh.VertexEntries.Count - 1;
  end
  else
    Result := -1;
end;

// Returns a face from the active queue to be completed. This needn't be the one at the
// end of the queue, because the choice of the next active face can affect how many SPLIT
// symbols are produced. This method employs a fairly simple scheme of searching the most
// recent 16 active faces for the first one with the smallest number of incomplete slots
// in its degree ring.

function TMeshDecoder.GetNextActiveFace: Integer;
var
  AEmptyDegree, ALowestEmptyDegree: Integer;
  i, AFaceIndex: Integer;
begin
  Result := -1;

  while ((ActiveFaces.Count > 0) and RemovedActiveFaces.TestBit(ActiveFaces[ActiveFaces.Count - 1])) do
    ActiveFaces.Delete(ActiveFaces.Count - 1);

  ALowestEmptyDegree := 9999999;

  i := ActiveFaces.Count - 1;
  while i >= Max(0, ActiveFaces.Count - 16) do
  begin
    AFaceIndex := ActiveFaces[i];
    if (RemovedActiveFaces.TestBit(AFaceIndex)) then
      ActiveFaces.Delete(i)
    else
    begin
      AEmptyDegree := DualMesh.FaceEntries[AFaceIndex].EmptyDegree;

      if (AEmptyDegree < ALowestEmptyDegree) then
      begin
        ALowestEmptyDegree := AEmptyDegree;
        Result := AFaceIndex;
      end;
    end;

    Dec(i);
  end;
end;

function TMeshDecoder.ActivateFace(AVertexIndex, AVertexFaceSlot: Integer): Integer;
var
  AFaceVertexSlot: Integer;
begin
  Result := CreateFace(AVertexIndex);

  if (Result >= 0) then // If a new active face
  begin
    DualMesh.SetVertexFace(AVertexIndex, AVertexFaceSlot, Result);
    DualMesh.SetFaceVertex(Result, 0, AVertexIndex);
    ActiveFaces.Add(Result);
  end
  else
  if (Result = -1) then	// Face already exists, so Split
  begin
    Result := GetFaceBySplitOffset;	// v's index in ActiveSet, returns v
    AFaceVertexSlot := GetNextSplitFacePos;
    DualMesh.SetVertexFace(AVertexIndex, AVertexFaceSlot, Result);
    AddVertexToFace(AVertexIndex, AVertexFaceSlot, Result, AFaceVertexSlot);
  end;
end;

// "Activates" the Vertex at AFaceIndex slot AFaceVertexSlot by calling ioFace() to
// obtain a new face number and hooking it up to the topological structure. Note
// that we use the term "activate" here to mean "read" for mesh decoding.

function TMeshDecoder.ActivateVertex(AFaceIndex, AFaceVertexSlot: Integer): Integer;
begin
  Result := CreateVertex;
  DualMesh.SetVertexFace(Result, 0, AFaceIndex);
  AddVertexToFace(Result, 0, AFaceIndex, AFaceVertexSlot);
end;

// Connects a Vertex (AVertexIndex) around a Face (AFaceIndex). First, it connects the Vertex
// to the Face at the given Slot (AFaceVertexSlot). Next, it will connect the Vertex with the
// Faces at the other ends of the shared edges, Clock-Wise and Counter-Clock-Wise, if not already
// connected there.

procedure TMeshDecoder.AddVertexToFace(AVertexIndex, AVertexFaceSlot, AFaceIndex, AFaceVertexSlot: Integer);
var
  AVertexFaceSlotCW, AVertexFaceSlotCCW: Integer;
  AFaceVertexSlotCW, AFaceVertexSlotCCW: Integer;
  vi, vfs: Integer;
begin
  AVertexFaceSlotCW := SubMod(AVertexFaceSlot, DualMesh.VertexEntries[AVertexIndex].Valence);
  AVertexFaceSlotCCW := AddMod(AVertexFaceSlot, DualMesh.VertexEntries[AVertexIndex].Valence);

  AFaceVertexSlotCW := SubMod(AFaceVertexSlot, DualMesh.FaceEntries[AFaceIndex].FaceDegree);
  AFaceVertexSlotCCW := AddMod(AFaceVertexSlot, DualMesh.FaceEntries[AFaceIndex].FaceDegree);

  { connect first at the given slot }

  DualMesh.SetFaceVertex(AFaceIndex, AFaceVertexSlot, AVertexIndex);

  { connect at clock wise degree }

  vi := DualMesh.GetFaceVertex(AFaceIndex, AFaceVertexSlotCW);
  if (vi <> -1) then
  begin
    vfs := DualMesh.FindVertexFaceSlot(vi, AFaceIndex);

    if (DualMesh.GetVertexFaceIndex(AVertexIndex, AVertexFaceSlotCCW) = -1) then
    begin
      DecMod(vfs, DualMesh.VertexEntries[vi].Valence);
      DualMesh.SetVertexFace(AVertexIndex, AVertexFaceSlotCCW, DualMesh.GetVertexFaceIndex(vi, vfs));
    end;
  end;

  { connect at counter clock wise degree }

  vi := DualMesh.GetFaceVertex(AFaceIndex, AFaceVertexSlotCCW);
  if (vi <> -1) then
  begin
    vfs := DualMesh.FindVertexFaceSlot(vi, AFaceIndex);

    if (DualMesh.GetVertexFaceIndex(AVertexIndex, AVertexFaceSlotCW) = -1) then
    begin
      IncMod(vfs, DualMesh.VertexEntries[vi].Valence);
      DualMesh.SetVertexFace(AVertexIndex, AVertexFaceSlotCW, DualMesh.GetVertexFaceIndex(vi, vfs));
    end;
  end;
end;


// Completes the Vertex (AVertexIndex) by activating its inactive incident Faces. The passed
// Slot (FaceVertexSlot) is the Face Vertex Sloat on Face 0 of the Vertex. This method begins
// at Face 0, working its way around the Vertex in CCW and CW directions, finding faces that
// can be linked without calling ActivateFace().
// This can
// happen when a face is completed by a nearby vertex before coming here. The situation can
// be detected by traversing the topology of the _pDstVFM over to the neighboring vertex and
// checking if it already has a face number for the corresponding face entry on iVtx. If so,
// then iVtx and the already completed face are connected together, and the next face around
// iVtx is examined. When the process can go no further, this method calls _activateF() on
// the remaining unresolved span of faces around the vertex.

procedure TMeshDecoder.CompleteVertex(AVertexIndex, AFaceVertexSlot: Integer);
var
  AFaceIndex, AFaceIndex0, AVertexFaceSlot: Integer;
  i, vi, fi, fvs: Integer;
begin
  // Walk CCW from face slot 0, attempting to link in as many already-reachable
  // faces as possible until we reach one that is inactive.

  AFaceIndex0 := DualMesh.GetVertexFaceIndex(AVertexIndex, 0);
  fvs := AFaceVertexSlot;
  i := 1;

  AFaceIndex := DualMesh.GetVertexFaceIndex(AVertexIndex, i);
  while (AFaceIndex <> -1) do	// Forces "FV" in the "next" direction
  begin
    DecMod(fvs, DualMesh.FaceEntries[AFaceIndex0].FaceDegree);

    vi := DualMesh.GetFaceVertex(AFaceIndex0, fvs);
    if (vi = -1) then
      Break;

    fvs := DualMesh.FindFaceVertexSlot(AFaceIndex, vi);
    DecMod(fvs, DualMesh.FaceEntries[AFaceIndex].FaceDegree);
    AddVertexToFace(AVertexIndex, i, AFaceIndex, fvs);

    AFaceIndex0 := AFaceIndex;

    Inc(i);
    if (i >= DualMesh.VertexEntries[AVertexIndex].Valence) then
      Exit;

    AFaceIndex := DualMesh.GetVertexFaceIndex(AVertexIndex, i);
  end;

  // Walk CW from face slot 0, attempting to link in as many already-reachable faces
  // as possible until we reach one that is inactive.

  AVertexFaceSlot := i;
  AFaceIndex0 := DualMesh.GetVertexFaceIndex(AVertexIndex, 0);
  fvs := AFaceVertexSlot;
  i := DualMesh.VertexEntries[AVertexIndex].Valence - 1;

  AFaceIndex := DualMesh.GetVertexFaceIndex(AVertexIndex, i);
  while (AFaceIndex <> -1) do	// Forces "VF" in "prev" direction
  begin
    IncMod(fvs, DualMesh.FaceEntries[AFaceIndex0].FaceDegree);

    vi := DualMesh.GetFaceVertex(AFaceIndex0, fvs);
    if (vi = -1) then
      Break;

    fvs := DualMesh.FindFaceVertexSlot(AFaceIndex, vi);
    IncMod(fvs, DualMesh.FaceEntries[AFaceIndex].FaceDegree);
    AddVertexToFace(AVertexIndex, i, AFaceIndex, fvs);

    AFaceIndex0 := AFaceIndex;

    Dec(i);
    if (i < AVertexFaceSlot) then
      Exit;

    AFaceIndex := DualMesh.GetVertexFaceIndex(AVertexIndex, i);
  end;

  // Activate the remaining faces on iVtx that cannot be decuced from
  // the already-assembled topology in the destination VFMesh.

  while (AVertexFaceSlot <= i) do
  begin
    fi := ActivateFace(AVertexIndex, AVertexFaceSlot);
    Inc(AVertexFaceSlot);
  end;
end;

// Completes a Face by going trough each of its Empty Slots (Degrees) and calling ActivateVertex()
// and CompleteVertex() for each inactive incident Vertexes in the face's degree ring.

procedure TMeshDecoder.CompleteFace(AFaceIndex: Integer);
var
  AVertexIndex, AFaceVertexSlot: Integer;
begin
  AFaceVertexSlot := DualMesh.FindFaceVertexSlot(AFaceIndex, -1);
  while (AFaceVertexSlot <> -1) do
  begin
    AVertexIndex := ActivateVertex(AFaceIndex, AFaceVertexSlot);
    CompleteVertex(AVertexIndex, AFaceVertexSlot);

    AFaceVertexSlot := DualMesh.FindFaceVertexSlot(AFaceIndex, -1);
  end;
end;

function TMeshDecoder.GetFaceBySplitOffset: Integer;
var
  ASplitFaceIndex: Integer;
begin
  ASplitFaceIndex := GetNextSplitFace;

  if ((ASplitFaceIndex < -1) or (ASplitFaceIndex > ActiveFaces.Count)) then
    raise Exception.Create('TMeshDecoder.GetFaceBySplitOffset()'#13 + 'Index is out of range');

  if (ASplitFaceIndex > -1) then
    Result := ActiveFaces[ActiveFaces.Count - ASplitFaceIndex]
  else
    Result := -1;
end;

function TMeshDecoder.RunComponent: Boolean;
var
  AVertexIndex, AFaceIndex, i: Integer;
begin
  // Call CreateVertex() to start us off with the seed face
  // from a new "connected component" of polygons.

  AVertexIndex := CreateVertex;
  if (AVertexIndex >= 0) then
  begin
    for i := 0 to DualMesh.VertexEntries[AVertexIndex].Valence - 1 do
      ActivateFace(AVertexIndex, i); // Process all faces

    AFaceIndex := GetNextActiveFace;
    while (AFaceIndex <> -1) do
    begin
      CompleteFace(AFaceIndex);
      RemovedActiveFaces.SetBit(AFaceIndex);
      AFaceIndex := GetNextActiveFace;
    end;

    Result := True;
  end
  else
    Result := False;
end;

end.
