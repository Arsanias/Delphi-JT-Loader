// Copyright (c) 2021 Arsanias (arsaniasbb@gmail.com)
// Distributed under the MIT software license, see the accompanying
// file LICENSE or http://www.opensource.org/licenses/mit-license.php.

unit
  JTCodec;

interface

uses
  System.SysUtils, System.Types, System.StrUtils, System.Variants, System.UITypes, System.ZLib,
  System.Classes, System.Math, Generics.Defaults, Generics.Collections,
  Vcl.Dialogs,
  Core.Utils, Core.Types, Core.ByteReader, Core.BitReader, Core.Loader;

type
  TCodecType = (ctNULL, ctBITLENGTH, ctHUFFMAN, ctARITHMETIC, ctCHOPPER, ctMOVETOFRONT);

  TPredictorType = (
    prNone,
    ptPredLag1,
	  ptPredLag2, // Predicts as last values
	  ptPredStride1,
    ptPredStride2,
	  ptPredStripIndex,
	  ptPredRamp,
	  ptPredXor1, // Predict as last, but use xor instead of subtract
	  ptPredXor2,
	  ptPredNULL  // No prediction
  );

  PProbabilityContextEntry = ^TProbabilityContextEntry;
  TProbabilityContextEntry = record // v8.1-229 // v10.0-215
  public
    Symbol: Integer;
    OccurenceCount: Cardinal;
    Value: Integer;
    NextContext: Integer; // v8.1 // v9.5
    CumulatedOccurenceCount: Integer; // v10.0
  end;

  TProbabilityContext = class // V8.1-226 // V9.5-255
  protected
    Entries: TList<PProbabilityContextEntry>;
    AccumulatedCount: Integer; // Accuulated Symbol Count
  public
    constructor Create;
    destructor Destroy; override;
  end;

  TInt32ProbabilityContextList = class
  private
    KeyArray: array[0..1] of TIntegerList;
    FContexts: array of TProbabilityContext;
    ProbCntxtAccumuMap: TList<TDictionary<Integer, Integer>>; // Accumulated occurence counts // TDictionary was TreeMap
    function GetCount: Integer;
  protected
    RequiresOutOfBandValues: Boolean;
  public
    constructor Create(Loader: TCoreLoader);
    destructor Destroy; override;
    function GetEntryAndSymbolRangeByRescaledCode(AContextIndex: Integer; AReScaledCode: Integer; ASymbolRange: PIntegerArray): PProbabilityContextEntry;
    procedure AccumulateProbabilityCounts;
    procedure AccumulateCounts; // v10.0
    function LookupEntryByCumCount(ACount: Int32): PProbabilityContextEntry; // v10.0
    property Count: Integer read GetCount;
  end;

  PCodecDriver = ^TCodecDriver;
  TCodecDriver = record
    CodecType: TCodecType;
    CodeText: TList<ShortInt>;
    CodeTextLength: Integer; // BitSize of CodeText
    IntsToRead: Integer;
    ValueCount: Integer;
    SymbolCount: Integer;
    ProbContexts: TInt32ProbabilityContextList;
    AccumSymbolCount: Integer;
    OutOfBandValues: TIntegerList;
    procedure Initialize;
    procedure Clear;
  end;

  TIntCDP = class // v8.1-225 // v9.5-258 // v10.0-155
  protected
    class function Decode(Loader: TCoreLoader): TIntegerList;
    class function DecodeNullCodec(Loader: TCoreLoader; AIntsToRead: Integer): TIntegerList;
    class function DecodeChopper(Loader: TCoreLoader; AValueCount: Integer): TIntegerList;
    class function DecodeMoveToFront(Loader: TCoreLoader): TIntegerList;
    class function GetCodeText(Loader: TCoreLoader; AIntsToRead: Integer): TList<ShortInt>;
    class function ReadCodecType(Loader: TCoreLoader): TCodecType;
    class procedure ReadProbContextsAndOutOfBandValues(Loader: TCoreLoader; ADriver: PCodecDriver);
    class function ReadOutOfBandValues(Loader: TCoreLoader): TIntegerList;
    class function PredictValue(Values: TIntegerList; Index: Integer; PredictorType: TPredictorType): Integer;
    class function UnpackResiduals(ASource: TIntegerList; APredictorType: TPredictorType): TIntegerList;
  public
    class function ReadVecI32(Loader: TCoreLoader; APredictorType: TPredictorType): TIntegerList;
    class function ReadVecU32(Loader: TCoreLoader; APredictorType: TPredictorType): TIntegerList;
  end;

  TArithmeticDecoder = class // v9.5-
    class function Decode(Loader: TCoreLoader; ADriver: PCodecDriver): TIntegerList;
  end;

  TBitlengthDecoder = class
  private
    class function NibblerGet(ABitReader: TBitReader): Integer;
  public
    class function Decode(Loader: TCoreLoader; ADriver: PCodecDriver): TIntegerList;
  end;

  TDeeringNormalCodec = class // v9.5-329
  public
    class procedure ConvertToVector(ABits: Integer; ASextantIndex, AOctantIndex, AThetaIndex, APsiIndex: Cardinal; AVector: PVector3);
  end;

  THuffCodeData = class
    Symbol: Integer;
    _codeLength: Integer;
    _bitCode: Int64;
    constructor Create(ASymbol: Integer; bitCode: Int64; codeLength: Integer);
  end;

  THuffTreeNode = class
    OccurenceCount: Integer;
    Value: Integer;
    _leftChildNode: THuffTreeNode;
    _rightChildNode: THuffTreeNode;
    Data: THuffCodeData;
    constructor Create;
  end;

  THuffCodecContext = class
    _length: Integer;
    _code: Int64;
    _huffCodeDatas: TList<THuffCodeData>;
    constructor Create;
  end;

  THuffHeap = class
    _heap: TList<THuffTreeNode>;
    constructor Create;
    procedure Add(huffTreeNode: THuffTreeNode);
    procedure remove();
    function getTop: THuffTreeNode;
  end;

  THuffmanDecoder = class
    class function Decode(Loader: TCoreLoader; ADriver: PCodecDriver): TIntegerList;
    class function BuildHuffmanTree(AEntries: TList<PProbabilityContextEntry>): THuffTreeNode;
    class procedure AssignCodeToTree(huffTreeNode: THuffTreeNode; huffCodecContext: THuffCodecContext);
    class function CodeTextToSymbols(ADriver: PCodecDriver; huffTreeNodes: TList<THuffTreeNode>): TList<Integer>;
  end;

implementation

constructor TProbabilityContext.Create;
begin
  Entries := TList<PProbabilityContextEntry>.Create;
  AccumulatedCount := 0;
end;

destructor TProbabilityContext.Destroy;
var
  i: Integer;
begin
  for i := 0  to Entries.Count - 1 do
    Dispose(Entries[i]);
  Entries.Free;

  inherited;
end;

//------------------------------------------------------------------------------

constructor TInt32ProbabilityContextList.Create(Loader: TCoreLoader);
var
  i, j: Integer;
  AContext: TProbabilityContext;
  AEntryCount: Integer;
  AEntry: PProbabilityContextEntry;
  ASymbolCountBits: UInt32;
  AOccurrenceCountBits: UInt32;
  ANumberNextContextBits: UInt32;
  ANumberValueBits: UInt32;
  AMinValue: Integer;
  AHashMap: TDictionary<Integer, Integer>; // Accumulated occurence counts // TDictionary was TreeMap
  AProbContextCount: Integer;
begin
  RequiresOutOfBandValues := False;
  ProbCntxtAccumuMap := nil;
  AHashMap := nil;
  KeyArray[0] := nil;
  KeyArray[1] := nil;

  if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 9.0)) then
    AProbContextCount := Loader.Read8
  else
    AProbContextCount := 1;
  SetLength(FContexts, AProbContextCount);

  if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 9.0)) then
  begin
    AHashMap := TDictionary<Integer, Integer>.Create;

    for i := 0 to AProbContextCount - 1 do
    begin
      AContext := TProbabilityContext.Create;
      FContexts[i] := AContext;

      AEntryCount := Cardinal(Loader.ReadUnsignedBits(32));
      ASymbolCountBits := Loader.ReadUnsignedBits(6);
      AOccurrenceCountBits := Loader.ReadUnsignedBits(6);

      if (i = 0) then
      begin
        ANumberValueBits := Loader.ReadUnsignedBits(6);
        ANumberNextContextBits := Loader.ReadUnsignedBits(6);
        AMinValue := Loader.ReadUnsignedBits(32);
      end
      else
      begin
        ANumberValueBits := 0;
        ANumberNextContextBits := Loader.ReadUnsignedBits(6);
      end;

      AContext.Entries.Capacity := AEntryCount;
      for j := 0 to AEntryCount - 1 do
      begin
        AEntry := New(PProbabilityContextEntry);

        AEntry.Symbol := Loader.ReadUnsignedBits(ASymbolCountBits) - 2;
        AEntry.OccurenceCount := Loader.ReadUnsignedBits(AOccurrenceCountBits);
        AEntry.Value := Loader.ReadUnsignedBits(ANumberValueBits) + AMinValue;
        if (ANumberNextContextBits <> -1) then
          AEntry.NextContext := Loader.ReadUnsignedBits(ANumberNextContextBits)
        else
          AEntry.NextContext := 0;

        if (i = 0) then
          AHashMap.Add(AEntry.Symbol, AEntry.Value)
        else
          AEntry.Value := AHashMap[AEntry.Symbol];

        AContext.Entries.Add(AEntry);
      end;
    end;
    SafeFree(AHashMap);
  end
  else
  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
  begin
    AContext := TProbabilityContext.Create;
    FContexts[0] := AContext;

    AEntryCount := Loader.ReadUnsignedBits(16);
    ASymbolCountBits := Loader.ReadUnsignedBits(6);
    AOccurrenceCountBits := Loader.ReadUnsignedBits(6);
    ANumberValueBits := Loader.ReadUnsignedBits(6);
    AMinValue := Loader.ReadUnsignedBits(32);

    AContext.Entries.Capacity := AEntryCount;

    for i := 0 to AEntryCount - 1 do
    begin
      AEntry := New(PProbabilityContextEntry);

      AEntry.Symbol := Loader.ReadUnsignedBits(ASymbolCountBits) - 2;
      AEntry.OccurenceCount := Loader.ReadUnsignedBits(AOccurrenceCountBits);
      AEntry.Value := Loader.ReadUnsignedBits(ANumberValueBits) + AMinValue;
      AEntry.NextContext := 0;

      AContext.Entries.Add(AEntry);
    end;
  end
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
  begin
    AContext := TProbabilityContext.Create;
    FContexts[0] := AContext;

    AEntryCount := Loader.ReadUnsignedBits(16);
    AOccurrenceCountBits := Loader.ReadUnsignedBits(6);
    ANumberValueBits := Loader.ReadUnsignedBits(7);
    AMinValue := Loader.ReadSignedBits(32);

    AContext.Entries.Capacity := AEntryCount;

    for i := 0 to AEntryCount - 1 do
    begin
      AEntry := New(PProbabilityContextEntry);

      AEntry.Symbol := Loader.ReadUnsignedBits(1);
      AEntry.OccurenceCount := Loader.ReadUnsignedBits(AOccurrenceCountBits);
      AEntry.Value := Loader.ReadUnsignedBits(ANumberValueBits) + AMinValue;

      if (AEntry.Symbol <> 0) then
        RequiresOutOfBandValues := True;

      AContext.Entries.Add(AEntry);
    end;
  end;

  if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 10.0)) then
    AccumulateProbabilityCounts
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    AccumulateCounts;
end;

destructor TInt32ProbabilityContextList.Destroy;
var
  i, j: Integer;
begin
  for i := 0 to Length(FContexts) - 1 do
  begin
    FContexts[i].Free;
    KeyArray[i].Free;
  end;
  SafeFree(ProbCntxtAccumuMap);
  inherited;
end;

function TInt32ProbabilityContextList.GetCount;
begin
  Result := Length(FContexts);
end;

procedure TInt32ProbabilityContextList.AccumulateProbabilityCounts;
var
  AAccumulatedCount: Integer;
  ADictionary: TDictionary<Integer, Integer>;
  i, j: Integer;
  AEntry: PProbabilityContextEntry;
begin
  ProbCntxtAccumuMap := TList<TDictionary<Integer, Integer>>.Create;

  for i := 0 to Length(FContexts) - 1 do
  begin
    AAccumulatedCount := 0;
    ADictionary := TDictionary<Integer, Integer>.Create;

    for j := 0 to FContexts[i].Entries.Count - 1 do
    begin
      AEntry := FContexts[i].Entries[j];
      AAccumulatedCount := AAccumulatedCount + AEntry.OccurenceCount;
      ADictionary.Add((AAccumulatedCount - 1), j);
    end;

    ProbCntxtAccumuMap.Add(ADictionary);
    FContexts[i].AccumulatedCount := AAccumulatedCount;

    KeyArray[i] := TList<Integer>.Create;
    KeyArray[i].AddRange(ADictionary.Keys.toArray);
    KeyArray[i].Sort;
  end;
end;

procedure TInt32ProbabilityContextList.AccumulateCounts;
var
  i: Integer;
  AContext: TProbabilityContext;
  AEntries: TList<PProbabilityContextEntry>;
begin
  AContext := FContexts[0];
  AEntries := FContexts[0].Entries;

  if (AEntries.Count = 0) then
  begin
    AContext.AccumulatedCount := 0;
    Exit;
  end;

  AEntries[0].CumulatedOccurenceCount := 0;

  for i:= 1 to AEntries.Count - 1 do
    AEntries[i].CumulatedOccurenceCount := AEntries[i-1].OccurenceCount + AEntries[i-1].CumulatedOccurenceCount;

  AContext.AccumulatedCount := AEntries[i-1].OccurenceCount + AEntries[i-1].CumulatedOccurenceCount;
end;

function TInt32ProbabilityContextList.GetEntryAndSymbolRangeByRescaledCode(AContextIndex: Integer; AReScaledCode: Integer; ASymbolRange: PIntegerArray): PProbabilityContextEntry;
var
  AKey, AValue: Integer;
  AKeyArray: TIntegerList;
  i: Integer;
begin
  // key := treeMap.higherKey(rescaledCode - 1); // HigherKey function does not exist
  // {OPTIMIZE} - Hier wurde eine Funktion implementiert, die den nächsten Key zu
  // des übergebenen Parameters - 1 findet. Dazu müssen die Keys in ein Array kopiert
  // sortiert und dann darin gesucht werden. "HIGHER-KEY"-Funktion existiert in Delphi leider nicht

  AKeyArray := KeyArray[AContextIndex];
  AKey := 0;
  for i := 0 to AKeyArray.Count - 1 do
  begin
    if AKeyArray[i] > (AReScaledCode - 1) then
    begin
      AKey := AKeyArray[i];
      Break;
    end;
  end;

  AValue := ProbCntxtAccumuMap[AContextIndex].Items[AKey];
  Result := FContexts[AContextIndex].Entries[AValue];

  ASymbolRange[0] := (AKey + 1 - Result.OccurenceCount);
  ASymbolRange[1] := AKey + 1;
  ASymbolRange[2] := FContexts[AContextIndex].AccumulatedCount;
end;

function TInt32ProbabilityContextList.LookupEntryByCumCount(ACount: Int32): PProbabilityContextEntry;
const
  SeqSearchLen = 4;
var
  EntryIndex: Integer;
  i, low, high, mid: Int32;
  AContext: TProbabilityContext;
  AEntries: TList<PProbabilityContextEntry>;
begin
  AContext := FContexts[0];
  AEntries := AContext.Entries;

  EntryIndex := 0;

  i := 0;
  Result := nil;

  { For short lists, do sequential search }

  if (AEntries.Count <= (SeqSearchLen * 2)) then
  begin
    i := 0;
    while ((i < AEntries.Count) and (ACount >= (AEntries[i].CumulatedOccurenceCount + AEntries[i].OccurenceCount))) do
      Inc(i);

    if(i >= AEntries.Count) then
      raise Exception.Create('Bad probability table');

    Result := AEntries[i];
  end
  else
  begin
    { For long lists, do a short sequential searches through most likely elements,
      then do a binary search through the rest. }

    for i := 0 to SeqSearchLen - 1 do
    begin
      if (ACount < (AEntries[i].CumulatedOccurenceCount + AEntries[i].OccurenceCount)) then
      begin
        Result := AEntries[i];
        Exit;
      end;
    end;

    low := i;
    high := AEntries.Count - 1;

    while (True) do
    begin
      if (high < low) then
        Break;

      mid := low + ((high - low) shr 1);
      if (ACount < AEntries[mid].CumulatedOccurenceCount) then
      begin
        high := mid - 1;
        Continue;
      end;

      if (ACount >= (AEntries[mid].CumulatedOccurenceCount + AEntries[mid].OccurenceCount)) then
      begin
        low := mid + 1;
        Continue;
      end;

      Result := AEntries[mid];
      Exit;
    end;

    raise Exception.Create('Bad probability table');
  end;
end;

//==============================================================================

class function TIntCDP.ReadVecI32(Loader: TCoreLoader; APredictorType: TPredictorType): TIntegerList;
var
  AIntegerList: TIntegerList;
begin
  AIntegerList := Decode(Loader);
  try
    Result := UnpackResiduals(AIntegerList, APredictorType);
  finally
    AIntegerList.Free;
  end;
end;

class function TIntCDP.ReadVecU32(Loader: TCoreLoader; APredictorType: TPredictorType): TIntegerList;
var
  AIntegerList: TIntegerList;
  i: Integer;
begin
  AIntegerList := Decode(Loader);
  try
    Result := UnpackResiduals(AIntegerList, APredictorType);
    for i := 0 to Result.Count - 1 do
      Result[i] := (Result[i] and $ffff);
  finally
    AIntegerList.Free;
  end;
end;

class function TIntCDP.Decode(Loader: TCoreLoader): TIntegerList;
var
  ADriver: TCodecDriver;
begin
  ADriver.Initialize;

  if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 9.0)) then
  begin
    ADriver.CodecType := ReadCodecType(Loader);
    if ((ADriver.CodecType = ctHUFFMAN) or (ADriver.CodecType = ctARITHMETIC)) then
      ReadProbContextsAndOutOfBandValues(Loader, @ADriver);

    if (ADriver.CodecType <> ctNULL) then
    begin
      ADriver.CodeTextLength := Loader.Read32;
      ADriver.ValueCount := Loader.Read32;
      if ((ADriver.ProbContexts <> nil) and (ADriver.ProbContexts.Count > 1)) then
        ADriver.SymbolCount := Loader.Read32
      else
        ADriver.SymbolCount := ADriver.ValueCount;
    end
    else
      Result := DecodeNullCodec(Loader, 0);

    ADriver.IntsToRead := Loader.Read32;
    ADriver.CodeText := GetCodeText(Loader, ADriver.IntsToRead);

    case ADriver.CodecType of
      ctARITHMETIC: Result := TArithmeticDecoder.Decode(Loader, @ADriver);
      ctBITLENGTH:  Result := TBitlengthDecoder.Decode(Loader, @ADriver);
      ctHUFFMAN:    Result := THuffmanDecoder.Decode(Loader, @ADriver);
    end;
  end
  else
  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
  begin
    ADriver.ValueCount := Loader.Read32;
    if (ADriver.ValueCount > 0) then
    begin
      ADriver.CodecType := ReadCodecType(Loader);
      if (ADriver.CodecType = ctCHOPPER) then
        Result := DecodeChopper(Loader, ADriver.ValueCount)
      else
      if (ADriver.CodecType = ctNULL) then
        Result := DecodeNullCodec(Loader, 0)
      else
      begin
        ADriver.CodeTextLength := Loader.Read32;
        ADriver.IntsToRead := Trunc((ADriver.CodeTextLength / 32.0) + 0.99);
        ADriver.CodeText := GetCodeText(Loader, ADriver.IntsToRead);

        if (ADriver.CodecType = ctBITLENGTH) then
          Result := TBitlengthDecoder.Decode(Loader, @ADriver)
        else
        if (ADriver.CodecType = ctARITHMETIC) then
        begin
          ADriver.SymbolCount := ADriver.ValueCount;
          ReadProbContextsAndOutOfBandValues(Loader, @ADriver);

          if ((ADriver.CodeTextLength = 0) and (ADriver.OutOfBandValues.Count = ADriver.ValueCount)) then
            Result := ADriver.OutOfBandValues
          else
            Result := TArithmeticDecoder.Decode(Loader, @ADriver);
        end;
      end;
    end
    else
      Result := CreateIntegerList(0);
  end
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
  begin
    ADriver.ValueCount := Loader.Read32;

    if (ADriver.ValueCount > 0) then
    begin
      ADriver.CodecType := ReadCodecType(Loader);

      if (ADriver.CodecType = ctCHOPPER) then
        Result := DecodeChopper(Loader, ADriver.ValueCount)
      else
      if (ADriver.CodecType = ctMOVETOFRONT) then
        Result := DecodeMoveToFront(Loader)
      else
      begin
        ADriver.CodeTextLength := Loader.Read32;
        ADriver.IntsToRead := Trunc((ADriver.CodeTextLength / 32.0) + 0.99);

        if (ADriver.CodecType <> ctNULL) then
          ADriver.CodeText := GetCodeText(Loader, ADriver.IntsToRead);

        case ADriver.CodecType of
          ctNULL: Result := DecodeNullCodec(Loader, ADriver.IntsToRead);
          ctBITLENGTH: Result := TBitlengthDecoder.Decode(Loader, @ADriver);
          ctARITHMETIC:
          begin
            ReadProbContextsAndOutOfBandValues(Loader, @ADriver);

            if ((ADriver.CodeTextLength = 0) and (ADriver.OutOfBandValues.Count = ADriver.ValueCount)) then
              Result := ADriver.OutOfBandValues
            else
              Result := TArithmeticDecoder.Decode(Loader, @ADriver);
          end;
        end;
      end;
    end
    else
      Result := CreateIntegerList(0);
  end;

  if (Result.Count <> ADriver.ValueCount) then
    raise Exception.Create('Codec produced wrong number of symbols: ' + Result.Count.toString + ' of ' + ADriver.ValueCount.toString + ' values decoded.');

  ADriver.Clear;
end;

class function TIntCDP.GetCodeText(Loader: TCoreLoader; AIntsToRead: Integer): TList<ShortInt>;
var
  i: Integer;
  Buffer: TShortIntDynArray;
begin
  Result := nil;
  if (AIntsToRead <= 0) then Exit;

  Result := TList<ShortInt>.Create;
  Result.Count := AIntsToRead * 4;
  for i := 0 to AIntsToRead - 1 do
  begin
    Loader.ReadBytes(TByteDynArray(Buffer), 4);
    if (Loader.Endian = TByteOrder.boLittleEndian) then
    begin
      Result[i * 4] := buffer[3];
      Result[(i * 4) + 1] := buffer[2];
      Result[(i * 4) + 2] := buffer[1];
      Result[(i * 4) + 3] := buffer[0];
    end
    else
    begin
      Result[i * 4] := buffer[0];
      Result[(i * 4) + 1] := buffer[1];
      Result[(i * 4) + 2] := buffer[2];
      Result[(i * 4) + 3] := buffer[3];
    end;
  end;
end;

class function TIntCDP.ReadCodecType(Loader: TCoreLoader): TCodecType;
begin
  Result := TCodecType(Loader.Read8);
  if ((Result < ctNULL) and (Result > ctMOVETOFRONT)) then
    raise Exception.Create('Found invalid codec type: ' + IntToStr(Integer(Result)));
end;

class procedure TIntCDP.ReadProbContextsAndOutOfBandValues(Loader: TCoreLoader; ADriver: PCodecDriver);
var
  AOutOfBandValueCount: Integer;
begin
  ADriver.ProbContexts := TInt32ProbabilityContextList.Create(Loader);

  if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 9.0)) then
  begin
    AOutOfBandValueCount := Loader.Read32;
    if (AOutOfBandValueCount > 0) then
      ADriver.OutOfBandValues := Decode(Loader);
  end
  else
  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
    ADriver.OutOfBandValues := Decode(Loader)
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
    if (ADriver.ProbContexts.RequiresOutOfBandValues) then
      ADriver.OutOfBandValues := Decode(Loader);
end;

class function TIntCDP.ReadOutOfBandValues(Loader: TCoreLoader): TIntegerList;
var
  AValueCount: Integer;
begin
  Result := nil;

  if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 9.0)) then
  begin
    AValueCount := Loader.Read32;
    if (AValueCount > 0) then
      Result := Decode(Loader);
  end
  else
  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
    Result := Decode(Loader);
end;

class function TIntCDP.DecodeNullCodec(Loader: TCoreLoader; AIntsToRead: Integer): TIntegerList;
var
  i: Integer;
begin
  if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 9.0)) then
    AIntsToRead := Loader.Read32
  else
  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
    AIntsToRead := Trunc(Loader.Read32 / 4);

  Result := CreateIntegerList(AIntsToRead);
  for i := 0 to AIntsToRead - 1 do
    Result.Add(Loader.Read32);
end;

class function TIntCDP.DecodeChopper(Loader: TCoreLoader; AValueCount: Integer): TIntegerList;
var
  ChopBits: Integer;
  ValueBias: Integer;
  ValueSpanBits: Integer;
  ChoppedMSBData: TIntegerList;
  ChoppedLSBData: TIntegerList;
  i: Integer;
begin
  ChopBits := Loader.Read8;

  if (ChopBits = 0) then
    Result := Decode(Loader)
  else
  begin
    ValueBias := Loader.Read32;
    ValueSpanBits := Loader.Read8;

    ChoppedMSBData := Decode(Loader);
    ChoppedLSBData := Decode(Loader);

    Result := CreateIntegerList(AValueCount);
    for i := 0 to ChoppedMSBData.Count - 1 do
      Result.Add((ChoppedLSBData[i] or (ChoppedMSBData[i] shl (ValueSpanBits - ChopBits))) + ValueBias);

    ChoppedMSBData.Free;
    ChoppedLSBData.Free;
  end;
end;

class function TIntCDP.PredictValue(Values: TIntegerList; Index: Integer; PredictorType: TPredictorType): Integer;
var
  v1: Integer;
  v2: Integer;
  v4: Integer;
begin
  v1 := Values[Index - 1];
  v2 := Values[Index - 2];
  v4 := Values[Index - 4];

  case (PredictorType) of
    ptPredLag1, ptPredXor1:
      Result := v1;
    ptPredLag2, ptPredXor2:
      Result := v2;
    ptPredStride1:
      Result := (v1 + (v1 - v2));
    ptPredStride2:
      Result := (v2 + (v2 - v4));
    ptPredStripIndex:
      if (((v2 - v4) < 8) and ((v2 - v4) > -8)) then
        Result := (v2 + (v2 - v4))
      else
        Result := (v2 + 2);
    ptPredRamp:
      Result := Index;
    else
      Result := v1;
  end;
end;

class function TIntCDP.UnpackResiduals(ASource: TIntegerList; APredictorType: TPredictorType): TIntegerList;
var
  iPredicted: Integer;
  i: Integer;
begin
  Result := CreateIntegerList(ASource.Count);

  for i := 0 to ASource.Count - 1 do
  begin
    if (APredictorType = TPredictorType.ptPredNULL) then
      Result.Add(ASource[i])
    else
    begin
      // The first four values are not handeled
      if (i < 4) then
        Result.add(ASource[i])
      else
      begin
        // Get a predicted value
        iPredicted := predictValue(Result, i, APredictorType);

        // Decode the residual as the current value XOR predicted
        if ((APredictorType = TPredictorType.ptPredXor1) or (APredictorType = TPredictorType.ptPredXor2)) then
          Result.Add(ASource[i] xor iPredicted) // original-operator war ^ statt xor

        // Decode the residual as the current value plus predicted
        else
          Result.Add(ASource[i] + iPredicted);
      end;
    end;
  end;
end;

class function TIntCDP.DecodeMoveToFront(Loader: TCoreLoader): TIntegerList;
var
  AWindowValues: TIntegerList;
  AWindowOffsets: TIntegerList;
  AOffset, ACounter, i: Integer;
begin
  Result := nil;

  AWindowValues := nil;
  AWindowOffsets := nil;
  ACounter := 0;

  try
    AWindowValues := Decode(Loader);
    AWindowOffsets := Decode(Loader);

    Result := CreateIntegerList(AWindowOffsets.Count);
    for i := 0 to AWindowOffsets.Count - 1 do
    begin
      AOffset := AWindowOffsets[i];
      if (AOffset < 0) then
      begin
        if (AOffset = -1) then
        begin
          AOffset := ACounter;
          Inc(ACounter);
        end
        else
          AOffset := 8 + AOffset;
      end;

      Result.Add(AWindowValues[AOffset]);
      AWindowValues.Move(AOffset, 0);
    end;
  finally
    SafeFree(AWindowValues);
    SafeFree(AWindowOffsets);
  end;
end;

//==============================================================================

procedure TCodecDriver.Initialize;
begin
  CodeText := nil;
  ProbContexts := nil;
  OutOfBandValues := nil;
end;

procedure TCodecDriver.Clear;
begin
  SafeFree(CodeText);
  SafeFree(ProbContexts);
  SafeFree(OutOfBandValues);
end;

//==============================================================================

class function TArithmeticDecoder.Decode(Loader: TCoreLoader; ADriver: PCodecDriver): TIntegerList;
var
  ACode, ALow, AHigh: Integer;
  ACurrentCode, ACurrentBits: Integer;
  ContextIndex: Integer;
  ASymbolRange: array[0..2] of Integer;
  OutOfBandIndex: Integer;
  i: Integer;
  ReScaledCode: Integer;
  AEntry: PProbabilityContextEntry;
  ARange: Integer;
  ABitReader: TBitReader;
  ABitsRead: Integer;

  procedure GetNextCode;
  begin
    ACurrentBits := Min(32, (ADriver.CodeTextLength - ABitsRead));
    ACurrentCode := ABitReader.ReadUnsigned(ACurrentBits);

    if (ACurrentBits < 32) then
      ACurrentCode := ACurrentCode shl (32 - ACurrentBits); // Fill up the trailing positions with "0"

    Inc(ABitsRead, ACurrentBits);
  end;
begin
  ABitReader := TBitReader.Create(TByteReader.Wrap(ADriver.CodeText), boBigEndian);
  Result := CreateIntegerList(ADriver.ValueCount);

  OutOfBandIndex := 0;

  ABitsRead := 0;
  ACurrentBits := 0;
  ACurrentCode := 0;

  ALow := $0000;
  AHigh := $FFFF;

  GetNextCode;
  ACode := (ACurrentCode shr 16) and $FFFF;
  ACurrentCode := ACurrentCode shl 16;
  ACurrentBits := ACurrentBits - 16;

  if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 10.0)) then
  begin
    ContextIndex := 0;

    for i := 0 to ADriver.SymbolCount - 1 do
    begin
      ReScaledCode := ((ACode - ALow + 1) * ADriver.ProbContexts.FContexts[ContextIndex].AccumulatedCount - 1) div (AHigh - ALow + 1);
      AEntry := ADriver.ProbContexts.GetEntryAndSymbolRangeByRescaledCode(ContextIndex, RescaledCode, @ASymbolRange);

      if ((AEntry.Symbol <> -2) or (ContextIndex <= 0)) then
      begin
        if (AEntry.Symbol = -2) and (OutOfBandIndex < ADriver.OutOfBandValues.Count) then
        begin
          Result.Add(ADriver.OutOfBandValues[OutOfBandIndex]);
          Inc(OutOfBandIndex);
        end
        else
          Result.Add(AEntry.Value);
      end;
      ContextIndex := AEntry.NextContext;

      ARange := AHigh - ALow + 1;
      AHigh := ALow + ((ARange * ASymbolRange[1]) div ASymbolRange[2] - 1);
      ALow  := ALow + ((ARange * ASymbolRange[0]) div ASymbolRange[2]);

      while True do
      begin
        if (((not(AHigh xor ALow)) and $8000) = 0) then
          if (((ALow and $4000) > 0) and ((AHigh and $4000) = 0)) then
          begin
            ACode := ACode xor $4000;
            ALow  := ALow and $3fff;
            AHigh := AHigh or $4000;
          end
          else
            Break;

        ALow  := (ALow shl 1) and $ffff;
        AHigh := (AHigh shl 1) and $ffff;
        AHigh := (AHigh or 1) and $ffff;;
        ACode := (ACode shl 1) and $ffff;

        if (ACurrentBits = 0) then
          GetNextCode;

        ACode := (ACode or ((ACurrentCode shr 31) and $00000001));
        ACurrentCode := ACurrentCode shl 1;
        Dec(ACurrentBits);
      end;
    end;
  end
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
  begin
    AEntry := nil;

    for i := 0 to ADriver.ValueCount - 1 do
    begin
      // Scale the current "code" into the range of counts presented by
      // the probcontext so we can look up the code.
      ReScaledCode := ((ACode - ALow + 1) * ADriver.ProbContexts.FContexts[0].AccumulatedCount - 1) div (AHigh - ALow + 1);
      AEntry := ADriver.ProbContexts.LookupEntryByCumCount(Integer(ReScaledCode));

      if (AEntry.Symbol = 0) then
        Result.Add(AEntry.Value)
      else
      begin
        Result.Add(ADriver.OutOfBandValues[OutOfBandIndex]);
        Inc(OutOfBandIndex);
      end;

      // RemoveSymbolFromStream
      // First, the range is expanded to account for the symbol removal.
      ARange := AHigh - ALow + 1;
      AHigh := ALow + Trunc((ARange * (AEntry.CumulatedOccurenceCount + AEntry.OccurenceCount)) / ADriver.ProbContexts.FContexts[0].AccumulatedCount - 1);
      ALow := ALow + Trunc((ARange * AEntry.CumulatedOccurenceCount) / ADriver.ProbContexts.FContexts[0].AccumulatedCount);

      //Next, any possible bits are shipped out.
      while True do
      begin
        // If the most signif digits match, the bits will be shifted out.
        if (((not(AHigh xor ALow)) and $8000) = 0) then
          if (((ALow shr 14 and $3) = 1) and ((AHigh shr 14 and $3) = 2)) then
          begin
            ACode := ACode xor $4000;
            ALow := ALow and $3FFF;
            AHigh := AHigh or $4000;
          end
          else
            Break;

        ALow  := (ALow shl 1) and $ffff;
        AHigh := (AHigh shl 1) and $ffff;
        AHigh := (AHigh or 1) and $ffff;;
        ACode := (ACode shl 1) and $ffff;

        if (ACurrentBits = 0) then
          GetNextCode;

        ACode := ACode or (ACurrentCode shr 31);
        ACurrentCode := ACurrentCode shl 1;
        Dec(ACurrentBits);
      end;
    end;
  end;

  if (ADriver.OutOfBandValues <> nil) and (OutOfBandIndex < ADriver.OutOfBandValues.Count) then
    raise Exception.Create('Not all Out-Of-Band-Values have been consumed.');

  ABitReader.Free;
end;

//==============================================================================

class procedure TDeeringNormalCodec.ConvertToVector(ABits: Integer; ASextantIndex, AOctantIndex, AThetaIndex, APsiIndex: Cardinal; AVector: PVector3);
const
  PsiMax = 0.615479709;
var
  ABitRange: UInt32;
  ACosTheta, ASinTheta, ACosPsi, ASinPsi: Single;
  ATheta, APsi: Single;
  xx, yy, zz: Single;
begin
  // Size of code = 6+2*numBits, and max code size is 32 bits,
  // so numBits must be <= 13.
  // Code layout: [sextant:3][octant:3][theta:numBits][psi:numBits]

  AVector^:= TVector3.Create(0, 0, 0);
  ABitRange := 1 shl ABits;

  // For sextants 1, 3, and 5, AThetaIndex needs to be incremented
  AThetaIndex := AThetaIndex + (ASextantIndex and 1);

  ATheta := ArcSin(Tan(PsiMax * (ABitRange - AThetaIndex) / ABitRange));
  APsi := PsiMax * (APsiIndex / ABitRange);
  ACosTheta := Cos(ATheta);
  ASinTheta := Sin(ATheta);
  ACosPsi := Cos(APsi);
  ASinPsi := Sin(APsi);

  AVector^ := TVector3.Create(ACosTheta * ACosPsi, ASinPsi, ASinTheta * ACosPsi);

  case ASextantIndex of
    1: AVector^ := TVector3.Create(AVector.Z, AVector.Y, AVector.X); // Mirror about x=z plane
    2: AVector^ := TVector3.Create(AVector.Y, AVector.Z, AVector.X); // Rotate CW
    3: AVector^ := TVector3.Create(AVector.Y, AVector.X, AVector.Z); // Mirror about x=y plane
    4: AVector^ := TVector3.Create(AVector.Z, AVector.X, AVector.Y); // Rotate CCW
    5: AVector^ := TVector3.Create(AVector.X, AVector.Z, AVector.Y); // Mirror about y=z plane
  end;

  if ((AOctantIndex and $04) = 0) then
    AVector.X := -AVector.X;

  if ((AOctantIndex and $02) = 0) then
    AVector.Y := -AVector.Y;

  if ((AOctantIndex and $01) = 0) then
    AVector.Z := -AVector.Z;
end;

//==============================================================================

class function TBitlengthDecoder.NibblerGet(ABitReader: TBitReader): Integer;
var
  sw, bMoreBits, ATemp, cNibbles: Cardinal;
begin
  Result := 0;
  bMoreBits := 0;
  cNibbles := 0;
  repeat
    ATemp := ABitReader.ReadUnsigned(4);
    ATemp := ATemp shl (cNibbles * 4);
    Result := Result or ATemp;
    bMoreBits := ABitReader.ReadUnsigned(1);
    Inc(cNibbles);
  until (bMoreBits = 0);

  sw := cNibbles * 4;
  if (sw < 32) then
  begin
    Result := Result shl (32 - sw);
    Result := SAR(Result, 32 - sw);
  end;
end;

class function TBitlengthDecoder.Decode(Loader: TCoreLoader; ADriver: PCodecDriver): TIntegerList;
type
  TBitFieldMode = (fmFixedWidth, fmVariableWidth);
const
  BITBLOCK_LEN = 4;
var
  ABitReader: TBitReader;
  ASymbol: Integer;
  AdjustmentBit: Integer;
  i, j: Integer;
  cBlkValBits, cBlkLenBits: Integer;
  cMaxFieldDecr, cMaxFieldIncr: Integer;
  cDeltaFieldWidth, cRunLen: Integer;
  AMinSymbolBitCount, AMaxSymbolBitCount: Integer;
  AMinSymbol, AMaxSymbol, AMeanSymbol: Integer;
  ABitFieldWidth: Integer;
begin
  ABitReader := TBitReader.Create(TByteReader.Wrap(ADriver.CodeText), boBigEndian);
  Result := CreateIntegerList(ADriver.ValueCount);

  if ((Loader.FileVersion >= 8.0) and (Loader.FileVersion < 9.0)) then
  begin
    ABitFieldWidth := 0;
    while (ABitReader.BitsRead < ADriver.CodeTextLength) do
    begin
      if (TBitFieldMode(ABitReader.ReadUnsigned(1)) = fmFixedWidth) then
      begin
        // Decode symbol with same bit field length
        ASymbol := -1;
        if (ABitFieldWidth = 0) then
          ASymbol := 0
        else
        begin
          ASymbol := ABitReader.ReadUnsigned(ABitFieldWidth);
          ASymbol := ASymbol shl (32 - ABitFieldWidth);
          ASymbol := SAR(ASymbol, 32 - ABitFieldWidth);
        end;

        Result.Add(ASymbol);
      end
      else
      begin
        AdjustmentBit := ABitReader.ReadUnsigned(1);

        repeat
          if (AdjustmentBit = 1) then
            ABitFieldWidth := ABitFieldWidth + 2
          else
            ABitFieldWidth := ABitFieldWidth - 2;
        until (ABitReader.ReadUnsigned(1) <> AdjustmentBit);

        // Decode symbol with new bit field length
        ASymbol := -1;
        if (ABitFieldWidth = 0) then
          ASymbol := 0
        else
        begin
          ASymbol := ABitReader.ReadUnsigned(ABitFieldWidth);
          ASymbol := ASymbol shl (32 - ABitFieldWidth);
          ASymbol := SAR(ASymbol, 32 - ABitFieldWidth);
        end;
        Result.Add(ASymbol);
      end;
    end;
  end
  else
  if ((Loader.FileVersion >= 9.0) and (Loader.FileVersion < 10.0)) then
  begin
    if (TBitFieldMode(ABitReader.ReadUnsigned(1)) = fmFixedWidth) then
    begin
      AMinSymbolBitCount := ABitReader.ReadUnsigned(6);
      AMaxSymbolBitCount := ABitReader.ReadUnsigned(6);

      AMinSymbol := ABitReader.ReadSigned(AMinSymbolBitCount);
      AMaxSymbol := ABitReader.ReadSigned(AMaxSymbolBitCount);

      ABitFieldWidth := (ADriver.CodeTextLength - ABitReader.BitsRead) div ADriver.ValueCount;

      // Read each fixed-width field and output the value
      while ((ABitReader.BitsRead < ADriver.CodeTextLength) or (Result.Count < ADriver.ValueCount)) do
      begin
        ASymbol := ABitReader.ReadUnsigned(ABitFieldWidth);
        ASymbol := ASymbol + AMinSymbol;
        Result.Add(ASymbol);
      end;
    end
    else
    begin
      // Write out the mean value
      AMeanSymbol := ABitReader.ReadSigned(32);
      cBlkValBits := ABitReader.ReadUnsigned(3);
      cBlkLenBits := ABitReader.ReadUnsigned(3);

      // Set the initial field-width
      cMaxFieldDecr := -(1 shl (cBlkValBits - 1));
      cMaxFieldIncr := (1 shl (cBlkValBits - 1)) - 1;
      ABitFieldWidth := 0;

      i := 0;
      while (i < ADriver.ValueCount) do
      begin
        // Adjust the current field width to the target field width
        repeat
          cDeltaFieldWidth := ABitReader.ReadSigned(cBlkValBits);
          ABitFieldWidth := ABitFieldWidth + cDeltaFieldWidth;
        until ((cDeltaFieldWidth <> cMaxFieldDecr) and (cDeltaFieldWidth <> cMaxFieldIncr));

        cRunLen := ABitReader.ReadUnsigned(cBlkLenBits);
        for j := i to i + cRunLen - 1 do
          Result.Add(ABitReader.ReadSigned(ABitFieldWidth) + AMeanSymbol);

        i := i + cRunLen;
      end;
    end;
  end
  else
  if ((Loader.FileVersion >= 10.0) and (Loader.FileVersion < 11.0)) then
  begin
    if (TBitFieldMode(ABitReader.ReadUnsigned(1)) = fmFixedWidth) then
    begin
      AMinSymbol := NibblerGet(ABitReader);
      AMaxSymbol := NibblerGet(ABItReader);

      ABitFieldWidth := (ADriver.CodeTextLength - ABitReader.BitsRead) div ADriver.ValueCount;

      while ((ABitReader.BitsRead < ADriver.CodeTextLength) or (Result.Count < ADriver.ValueCount)) do
      begin
        ASymbol := ABitReader.ReadUnsigned(ABitFieldWidth);
        ASymbol := ASymbol + AMinSymbol;
        Result.Add(ASymbol);
      end;
    end
    else
    begin
      AMeanSymbol := NibblerGet(ABitReader);

      cMaxFieldDecr := -(1 shl (BITBLOCK_LEN - 1));		  // -ve number
      cMaxFieldIncr :=  (1 shl (BITBLOCK_LEN - 1)) - 1;	// +ve number

      ABitFieldWidth := 0;
      i := 0;
      while (i < ADriver.ValueCount) do
      begin
        repeat
          cDeltaFieldWidth := ABitReader.ReadSigned(BITBLOCK_LEN);
          ABitFieldWidth := ABitFieldWidth + cDeltaFieldWidth;
        until ((cDeltaFieldWidth <> cMaxFieldDecr) and (cDeltaFieldWidth <> cMaxFieldIncr));

        cRunLen := ABitReader.ReadUnsigned(BITBLOCK_LEN);
        for j := i to i + cRunLen - 1 do
          Result.Add(ABitReader.ReadSigned(ABitFieldWidth) + AMeanSymbol);

        i := i + cRunLen;
      end;
    end;
  end;

  if ((ABitReader.BitsRead <> ADriver.CodeTextLength) or (Result.Count <> ADriver.ValueCount)) then
    raise Exception.Create('TBitLengthCoded.Decode()#13#10' +
      'Mismatch between expected and returned values.');

  ABitReader.Free;
end;

//==============================================================================

constructor THuffCodeData.Create(ASymbol: Integer; bitCode: Int64; codeLength: Integer);
begin
  Symbol := ASymbol;
  _codeLength := codeLength;
  _bitCode := bitCode;
end;

//------------------------------------------------------------------------------

constructor THuffTreeNode.Create;
begin
  Data := THuffCodeData.Create(0, 0, 0);
  OccurenceCount := 0;
  Value := 0;
end;

//------------------------------------------------------------------------------

constructor THuffCodecContext.Create;
begin
  _length := 0;
  _code := 0;
  _huffCodeDatas := TList<THuffCodeData>.Create;
end;

//------------------------------------------------------------------------------

constructor THuffHeap.Create;
begin
  _heap := TList<THuffTreeNode>.Create;
end;

procedure THuffHeap.Add(huffTreeNode: THuffTreeNode);
var
  i: Integer;
begin
  _heap.Add(huffTreeNode);

  i := _heap.Count;

  // As long, as it isn't the root (1) and parent of i (i / 2 - 1) "bigger" than the new element is ...
  while ((i <> 1) and (_heap[(i div 2) - 1].OccurenceCount > huffTreeNode.OccurenceCount)) do
  begin
    // overwrite i with the parent of i
    _heap[i - 1] := _heap[(i div 2) - 1];

    // Parent of i is a new i
    i := i div 2;
  end;

  // Overwrite current position (i) with the new element
  _heap[i - 1] := huffTreeNode;
end;

procedure THuffHeap.remove();
var
  size, i, ci: Integer;
  y: THuffTreeNode;
begin
  if (_heap.Count = 0) then Exit;

  size := _heap.Count;
  y := _heap[size - 1];	// Re-insert the last element, because the list will be shortned by one
  i := 1;								// i is current "parent", which shall be removed / overwritten
  ci := 2;							// ci is current "child"
  size := size - 1;			// The new size is decremented by one

  while (ci <= size) do
  begin
    // Go to the left or to the right? Use the "smaller" element
    if ((ci < size) and (_heap[ci - 1].OccurenceCount > _heap[ci].OccurenceCount)) then
      ci := ci + 1;

    // If the new "last" element already fits (it has to be smaller than the smallest
    // childs of i), than break the loop
    if (y.OccurenceCount < _heap[ci - 1].OccurenceCount) then
      Break
    // Otherwise move the "child" up to the "parent" and continue with i at ci
    else
    begin
      _heap[i - 1] := _heap[ci - 1];
      i := ci;
      ci := ci * 2;
    end;
  end;

  // Set "last" element to the current position i
  _heap[i - 1] := y;

  // Resize node list by -1
  _heap.Delete(_heap.Count - 1);
end;

function THuffHeap.getTop: THuffTreeNode;
var
  huffTreeNode: THuffTreeNode;
begin
  if (_heap.Count = 0) then Exit(nil);

  huffTreeNode := _heap[0];
  Remove;
  Result := HuffTreeNode;
end;

//------------------------------------------------------------------------------

class function THuffmanDecoder.Decode(Loader: TCoreLoader; ADriver: PCodecDriver): TIntegerList;
var
  HuffmanRootNodes: TList<THuffTreeNode>;
  numberOfProbabilityContexts: Integer;
  vHuffCntx: TList<THuffCodecContext>;
  i: Integer;
  probabilityContextEntries: TList<PProbabilityContextEntry>;
  rootNode: THuffTreeNode;
begin
  HuffmanRootNodes := TList<THuffTreeNode>.Create;
  NumberOfProbabilityContexts := ADriver.ProbContexts.Count;
  vHuffCntx := TList<THuffCodecContext>.Create;

  for i := 0 to numberOfProbabilityContexts - 1 do
  begin
    // Get the i'th probability context
    ProbabilityContextEntries := ADriver.ProbContexts.FContexts[i].Entries;

    // Create Huffman tree from probability context
    RootNode := BuildHuffmanTree(probabilityContextEntries);

    // Assign Huffman codes
    vHuffCntx.Add(THuffCodecContext.Create);
    AssignCodeToTree(RootNode, vHuffCntx[i]);

    // Store the completed Huffman tree
    HuffmanRootNodes.Insert(i, rootNode);
  end;

  // Convert codetext to symbols
  Result := CodeTextToSymbols(ADriver, HuffmanRootNodes);
end;

class function THuffmanDecoder.BuildHuffmanTree(AEntries: TList<PProbabilityContextEntry>): THuffTreeNode;
var
  HuffHeap: THuffHeap;
  HuffTreeNode: THuffTreeNode;
  EntryCount: Integer;
  i: Integer;
  AEntry: PProbabilityContextEntry;
  newNode1: THuffTreeNode;
  newNode2: THuffTreeNode;
begin
  huffHeap := THuffHeap.Create;

  // Initialize all the nodes and add them to the heap.
  EntryCount := AEntries.Count;
  for i := 0 to EntryCount - 1 do
  begin
    AEntry := AEntries[i];
    HuffTreeNode := THuffTreeNode.Create;
    HuffTreeNode.Data.Symbol := AEntry.Symbol;
    HuffTreeNode.OccurenceCount := AEntry.OccurenceCount;
    HuffTreeNode.Value := AEntry.Value;

    HuffTreeNode._leftChildNode := nil;
    HuffTreeNode._rightChildNode := nil;

    HuffHeap.Add(HuffTreeNode);
  end;

  while (HuffHeap._heap.Count > 1) do
  begin
    // Get the two lowest-frequency nodes.
    newNode1 := huffHeap.getTop;
    newNode2 := huffHeap.getTop;

    //Combine the low-freq nodes into one node.
    huffTreeNode := THuffTreeNode.Create;
    huffTreeNode.Data.Symbol := $DEADBEEF;
    huffTreeNode._leftChildNode := newNode1;
    huffTreeNode._rightChildNode := newNode2;
    huffTreeNode.OccurenceCount := newNode1.OccurenceCount + newNode2.OccurenceCount;

    //Add the new node to the node list
    HuffHeap.Add(huffTreeNode);
  end;

  // Set the root node
  Result := HuffHeap.getTop;
end;

class procedure THuffmanDecoder.AssignCodeToTree(HuffTreeNode: THuffTreeNode; HuffCodecContext: THuffCodecContext);
begin
  if (huffTreeNode._leftChildNode <> nil) then
  begin
    huffCodecContext._code := (huffCodecContext._code shl 1) and $ffff;
    huffCodecContext._code := (huffCodecContext._code or 1) and $ffff;
    huffCodecContext._length := huffCodecContext._length + 1;
    AssignCodeToTree(HuffTreeNode._leftChildNode, huffCodecContext);
    huffCodecContext._length := HuffCodecContext._length - 1;
    huffCodecContext._code := SAR(huffCodecContext._code, 1); // was >>>
  end;

  if (huffTreeNode._rightChildNode <> nil) then
  begin
    huffCodecContext._code := (huffCodecContext._code shl 1) and $ffff;
    huffCodecContext._length := huffCodecContext._length + 1;
    assignCodeToTree(huffTreeNode._rightChildNode, huffCodecContext);
    huffCodecContext._length := huffCodecContext._length - 1;
    huffCodecContext._code := SAR(huffCodecContext._code, 1); // was >>>
  end;

  if (huffTreeNode._rightChildNode <> nil) then Exit;

  // Set the code and its length for the node.
  huffTreeNode.Data._bitCode := huffCodecContext._code;
  huffTreeNode.Data._codeLength := huffCodecContext._length;

  // Setup the internal symbol look-up table.
  HuffCodecContext._huffCodeDatas.Insert(0,
    THuffCodeData.Create(
      huffTreeNode.Data.Symbol,
      huffTreeNode.Data._bitCode,
      huffTreeNode.Data._codeLength));
end;

class function THuffmanDecoder.CodeTextToSymbols(ADriver: PCodecDriver; HuffTreeNodes: TList<THuffTreeNode>): TList<Integer>;
var
  huffTreeRootNode: THuffTreeNode;
  huffTreeNode: THuffTreeNode;
  ABitReader: TBitReader;
  OutOfBandIndex: Integer;
  symbol: Integer;
begin
  ABitReader := TBitReader.Create(TByteReader.Wrap(ADriver.CodeText), boBigEndian);
  Result := TList<Integer>.Create;
  OutOfBandIndex := 0;

  for huffTreeRootNode in huffTreeNodes do
  begin
    huffTreeNode := huffTreeRootNode;
    while (ABitReader.BitsRead < ADriver.CodeTextLength) do
    begin
      if (ABitReader.ReadUnsigned(1) = 1) then
        HuffTreeNode := huffTreeNode._leftChildNode
      else
        HuffTreeNode := huffTreeNode._rightChildNode;

      // If the node is a leaf, output a symbol and restart
      if ((HuffTreeNode._leftChildNode = nil) and (HuffTreeNode._rightChildNode = nil)) then
      begin
        symbol := HuffTreeNode.Data.Symbol;

        if (symbol = -2) then
        begin
          if (OutOfBandIndex < ADriver.OutOfBandValues.Count) then
          begin
            Result.Add(ADriver.OutOfBandValues[OutOfBandIndex]);
            Inc(OutOfBandIndex);
          end
          else
            raise Exception.Create('Out-Of-Band: Data missing!');
        end
        else
          Result.Add(HuffTreeNode.Value);
        huffTreeNode := huffTreeRootNode;
      end;
    end;
  end;

  ABitReader.Free;
end;

end.
