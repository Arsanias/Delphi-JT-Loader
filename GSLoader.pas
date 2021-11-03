// Copyright (c) 2021 Arsanias
// Distributed under the MIT software license, see the accompanying
// file LICENSE or http://www.opensource.org/licenses/mit-license.php.

unit
  GSLoader;

interface

uses
  System.SysUtils, System.Types, System.StrUtils, System.Variants, System.UITypes, System.ZLib,
  System.Classes,
  Generics.Defaults, Generics.Collections,
  Core.Utils, Core.Types, Core.ByteReader, Core.BitReader;

type
  PShortIntArray = ^TShortIntArray;
  TShortIntArray = TByteArray;

  Long = Int64;
  SinglePtr = ^Single;

  TRange = record
    Min: Integer;
    Max: Integer;
  end;

  TRangeF = record
    Min: Single;
    Max: Single;
  end;

  GSHashTable = class(TDictionary<Integer, Integer>)
  end;

  GSFile = class
  private
    procedure SetEndian(AEndian: TByteOrder);
  protected
    FFile: TFileStream;
    FEndian: TByteOrder;
    FBufferBitReader: TBitReader;
    FFileBitReader: TBitReader;
    FByteBuffer: TByteReader;
    FFileVersion: Variant;
    class function BSwap16(I: WORD): WORD; { inline; }
    class function BSwap32(I: DWORD): DWORD; { inline; }
    class function BSwap64(I: UInt64): UInt64; { inline; }
    function IntToBin(p_nb_int: uint64; p_nb_digits: byte=64): string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure AddLog(AClassName: string; AValueCount: Integer);
    function Open(AFileName: string): Boolean; virtual;
    function Read(var ABuffer; ASize: Integer): Integer;
    function Read8: Byte;
    function Read16: Word;
    function Read32: Integer;
    function Read64: UInt64;
    function ReadF32: Single;
    function ReadF64: Double;
    function ReadVec32(var AArray: TIntegerDynArray): Integer; overload;
    function ReadVec32(ABuffer: PInteger; ACount: Integer): Integer; overload;
    function ReadVec32(var AArray: TInt64DynArray): Integer; overload;
    function ReadVecU32(var AArray: TCardinalDynArray): Integer; overload;
    function ReadVecU32(var AArray: TIntegerDynArray): Integer; overload;
    function ReadVecF32(var AArray: TSingleDynArray): Integer; overload;
    function ReadVecF32(ABuffer: PSingle; ACount: Integer): Integer; overload;
    function FetchBytes(ASize: Integer): Integer;
    function ReadSignedBits(ASize: Integer): Integer;
    function ReadUnsignedBits(ASize: Integer): Cardinal;
    function FetchCompressedBytes(ACompressedSize: Integer; var AUncompressedSize: Cardinal): Integer;
    function FetchCompressedBytesLZMA(ACompressedSize: Integer; var AUncompressedSize: Cardinal): Integer;
    function ReadGUID: TGUID;
    function ReadString: string;
    function Skip(ALength: Cardinal): Cardinal;
    class function Dequantize(vertexCoordinates: TList<Integer>; Range: TRangeF; numberOfBits: Integer): TSingleList;
    function Seek(APosition: Int64): Int64;
    function ReadBytes(var ABuffer: TByteDynArray; ASize: Integer): Integer;
    property ByteBuffer: TByteReader read FByteBuffer;
    property File_: TFileStream read FFile;
    property FileVersion: Variant read FFileVersion;
    property Endian: TByteOrder read FEndian write SetEndian;
  end;

  TNotepad = class
  private
    FStrings: TStrings;
    FCounter: Integer;
    function GetText: string;
    procedure SetText(const S: string);
  public
    DoLogging: Boolean;
    constructor Create;
    procedure Add(const S: string);
    procedure AddLog(AClassName: string; AValueCount, AFilePos: Int64);
    procedure AddList(AName: string; AList: TList<Integer>; ALimit: Integer); overload;
    procedure AddList(AName: string; AList: TList<UInt64>; ALimit: Integer); overload;
    procedure AddList(AName: string; AList: TList<Single>; ALimit: Integer); overload;
    procedure SaveToFile(APath: string);
    procedure StartLogging;
    procedure AddBreak;
    property Text: string read GetText write SetText;
    property counter: integer read FCounter;
  end;

  function Hash32(APointer: Pointer; ACount: Integer; AHash: Cardinal): Cardinal;
  function Hash16(APointer: Pointer; ALength: Integer; AHAsh: Cardinal): Cardinal;

var
  Notepad: TNotepad;

implementation

uses
  libLZMA;

constructor GSFile.Create;
begin
  FFileBitReader := nil;
  FByteBuffer := TByteReader.Create(0);

  FBufferBitReader := TBitReader.Create(FByteBuffer, boBigEndian);
  Notepad := TNotepad.Create;
end;

destructor GSFile.Destroy;
begin
  SafeFree(Notepad);
  SafeFree(FByteBuffer);
  Safefree(FBufferBitReader);
  SafeFree(FFileBitReader);
  inherited;
end;

function GSFile.Read(var ABuffer; ASize: Integer): Integer;
begin
  if ((ByteBuffer.Position < ByteBuffer.Capacity) and
    ((FBufferBitReader.BitsRead mod 8) <> 0)) then                              // Resets the Reader Status if it was
      FBufferBitReader.Reset;                                                   // in use to be back aligned in 8 Bit

  if (ByteBuffer.Position < ByteBuffer.Capacity) then
    Result := ByteBuffer.Read(ABuffer, ASize)
  else
  begin
    if ((FFileBitReader.BitsRead mod 8) <> 0) then                              // Resets the Reader Status if it was
      FFileBitReader.Reset;                                                     // in use to be back aligned in 8 Bit
    Result := FFile.Read(ABuffer, ASize);
  end;
end;

function GSFile.Read8;
begin
  Read(Result, 1);
end;

function GSFile.Read16;
begin
  Read(Result, 2);
  if Endian = boBigEndian then Result := BSwap16(Result);
end;

function GSFile.Read32;
begin
  Read(Result, 4);
  if Endian = boBigEndian then Result := BSwap32(Result);
end;

function GSFile.Read64;
begin
  Read(Result, 8);
  if Endian = boBigEndian then Result := BSwap64(Result);
end;

function GSFile.ReadF32: Single;
var
  Buffer: array[0..3] of Byte;
begin
  Read(Buffer[0], 1);
  Read(Buffer[1], 1);
  Read(Buffer[2], 1);
  Read(Buffer[3], 1);

  Result := PSingle(@Buffer[0])^;
end;

function GSFile.ReadF64: Double;
var
  Buffer: array[0..7] of Byte;
begin
  Read(Buffer[0], 1);
  Read(Buffer[1], 1);
  Read(Buffer[2], 1);
  Read(Buffer[3], 1);
  Read(Buffer[4], 1);
  Read(Buffer[5], 1);
  Read(Buffer[6], 1);
  Read(Buffer[7], 1);

  Result := PSingle(@Buffer[0])^;
end;

function GSFile.ReadVec32(var AArray: TIntegerDynArray): Integer;
begin
  Result := Read32;
  SetLength(AArray, Result);
  ReadVec32(@AArray[0], Result);
end;

function GSFile.ReadVec32(ABuffer: PInteger; ACount: Integer): Integer;
var
  i: Integer;
begin
  for i := 0 to ACount - 1 do
  begin
    ABuffer^ := Read32;
    ABuffer := Pointer(Cardinal(ABuffer) + 4);
  end;
  Result := i;
end;

function GSFile.ReadVec32(var AArray: TInt64DynArray): Integer;
var
  i: Integer;
  ACount: Integer;
begin
  ACount := Read32;
  SetLength(AArray, ACount);
  for i := 0 to ACount - 1 do
    AArray[i] := Read32;
  Result := i;
end;

function GSFile.ReadVecU32(var AArray: TCardinalDynArray): Integer;
var
  i: Integer;
begin
  Result := Read32;
  SetLength(AArray, Result);
  for i := Low(AArray) to High(AArray) do
    AArray[i] := Read32;
end;

function GSFile.ReadVecU32(var AArray: TIntegerDynArray): Integer;
var
  i: Integer;
begin
  Result := Read32;
  SetLength(AArray, Result);
  for i := Low(AArray) to High(AArray) do
    AArray[i] := Read32;
end;

function GSFile.ReadVecF32(var AArray: TSingleDynArray): Integer;
begin
  Result := Read32;
  SetLength(AArray, Result);
  ReadVecF32(@AArray[0], Result);
end;

function GSFile.ReadVecF32(ABuffer: PSingle; ACount: Integer): Integer;
var
  i: Integer;
begin
  for i := 0 to ACount - 1 do
  begin
    ABuffer^ := ReadF32;
    ABuffer := Pointer(Cardinal(ABuffer) + 4);
  end;
  Result := i;
end;

function GSFile.FetchBytes(ASize: Integer): Integer;
var
  i: Integer;
  CompressedBytes: TByteDynArray;
  UncompressedSize: TByteReader;
  ByteBufferEndPos: Cardinal;
  PosMarker: Int64;
begin
  PosMarker := ByteBuffer.Capacity;
  ByteBuffer.Capacity := ByteBuffer.Capacity + ASize; // Extend the ByteBuffer's Capcity
  FFile.Read(ByteBuffer.Buffer[PosMarker], ASize); // Read Bytes into the ByteBuffer
end;

function GSFile.FetchCompressedBytes(ACompressedSize: Integer; var AUncompressedSize: Cardinal): Integer;
var
  i: Integer;
  CompressedBytes: TByteDynArray;
  ByteBufferEndPos: Cardinal;
  PosMarker: Int64;
  DataBuffer: TByteDynArray;
  AZLibResult: Integer;
  AResultSize: Cardinal;
begin
  SetLength(CompressedBytes, ACompressedSize);
  FFile.Read(CompressedBytes[0], ACompressedSize); // Read Compressed Bytes into a Buffer

  if (AUncompressedSize = 0) then
    AResultSize := 960000
  else
    AResultSize := AUncompressedSize;
  SetLength(DataBuffer, AResultSize);

  AZLibResult := Uncompress(@DataBuffer[0], AResultSize, @CompressedBytes[0], ACompressedSize);
  if (AZLibResult <> Z_OK) then
    raise Exception.Create('ZLib decompression seems to be failed! Expected length: ' + IntToStr(AUncompressedSize) + ' -> resulting length: ' + IntToStr(AUncompressedSize));

  AUncompressedSize := AResultSize;
  ByteBuffer.Capacity := ByteBuffer.Capacity + AUncompressedSize; // Extend the ByteBuffer's Capcity
  for i := 0 to AUncompressedSize - 1 do
    ByteBuffer.Buffer[ByteBuffer.Position + i] := DataBuffer[i];
end;

function GSFile.FetchCompressedBytesLZMA(ACompressedSize: Integer; var AUncompressedSize: Cardinal): Integer;
const
  ABufferSize = 65536;
var
  AInputStream, AOutputStream: TStream;
  ADecoder: TXZDecompressionStream;
  ABuffer: array[0..ABufferSize-1] of Byte;
  ACount, i: Integer;
  v: Byte;
begin
  AUncompressedSize := 0;

  if LoadLZMADLL then
  begin
    AInputStream := TMemoryStream.Create;
    AOutputStream := TMemoryStream.Create;
    try
      AInputStream.CopyFrom(FFile, ACompressedSize);
      AInputStream.Position := 0;

      ADecoder := TXZDecompressionStream.Create(AInputStream);
      try
        while True do
        begin
          ACount := ADecoder.Read(ABuffer, ABufferSize);
          if (ACount <> 0) then
            AOutputStream.WriteBuffer(ABuffer, ACount)
          else
            Break;
        end;
      finally
        ADecoder.Free;
        AInputStream.Free;
      end;
    finally
      AOutputStream.Position := 0;
      AUncompressedSize := AOutputStream.Size;

      ByteBuffer.Capacity := ByteBuffer.Capacity + AUncompressedSize; // Extend the ByteBuffer's Capcity
      for i := 0 to AUncompressedSize - 1 do
      begin
        AOutputStream.Read(v, 1);
        ByteBuffer.Buffer[ByteBuffer.Position + i] := v;
      end;

      AOutputStream.Free;
    end;
    UnloadLZMADLL;
  end
  else
    raise Exception.CreateFmt('%s not found.',[LZMA_DLL]);
end;

function GSFile.ReadGUID: TGUID;
begin
  Result.D1 := Read32;
  Result.D2 := Read16;
  Result.D3 := Read16;

  Read(Result.D4, 8);
end;

function GSFile.ReadString: string;
var
  ACount, i: Integer;
  ABuffer: array[0..2000] of Word;
begin
  ACount := Read32;
  if (ACount > 0) then
  begin
    for i := 0 to ACount - 1 do
      ABuffer[i] := Read16;

    SetString(Result, PChar(@ABuffer[0]), ACount);
  end
  else
    Result := '';
end;

function GSFile.ReadSignedBits(ASize: Integer): Integer;
begin
  if (ByteBuffer.Position < ByteBuffer.Capacity) then
    Result := FBufferBitReader.ReadSigned(ASize)
  else
    Result := FFileBitReader.ReadSigned(ASize);
end;

function GSFile.ReadUnsignedBits(ASize: Integer): Cardinal;
begin
  if (ByteBuffer.Position < ByteBuffer.Capacity) then
    Result := FBufferBitReader.ReadUnsigned(ASize)
  else
    Result := FFileBitReader.ReadUnsigned(ASize);
end;

function GSFile.Skip(ALength: Cardinal): Cardinal;
begin
  if (ByteBuffer.Position < ByteBuffer.Capacity) then
    ByteBuffer.Position := ByteBuffer.Position + ALength
  else
    FFile.Seek(ALength, soFromCurrent);
  Result := ALength;
end;

procedure GSFile.SetEndian(AEndian: TByteOrder);
begin
  FEndian := AEndian;
end;

class function GSFile.Dequantize(vertexCoordinates: TList<Integer>; Range: TRangeF; numberOfBits: Integer): TSingleList;
var
  minimum: Single;
  maximum: Single;
  maxCode: Int64;
  encodeMultiplier: Double;
  DequantizesVertices: TSingleList;
  i: Integer;
begin
  minimum := Range.Min;
  maximum := Range.Max;
  maxCode := $ffffffff;

  if (numberOfBits < 32) then
    maxCode := $1 shl numberOfBits;

  EncodeMultiplier := maxCode / (maximum - minimum);

  DequantizesVertices := CreateSingleList(VertexCoordinates.Count);
  for i := 0 to VertexCoordinates.Count - 1 do
    DequantizesVertices.Add((((vertexCoordinates[i] - 0.5) / EncodeMultiplier + Minimum)));

  Result := DequantizesVertices;
end;

function GSFile.Seek(APosition: Int64): Int64;
begin
  Result := FFile.Seek(APosition, soFromBeginning);
end;

function GSFile.ReadBytes(var ABuffer: TByteDynArray; ASize: Integer): Integer;
begin
  SetLength(ABuffer, ASize);
  Result := Read(ABuffer[0], ASize);
end;

class function GSFile.BSwap32(I: DWORD): DWORD;
var
  ABuffer: array[0..3] of Byte;
begin
  //BSWAP   EAX
  ABuffer[0] := PByteArray(Pointer(@I))^[3];
  ABuffer[1] := PByteArray(Pointer(@I))^[2];
  ABuffer[2] := PByteArray(Pointer(@I))^[1];
  ABuffer[3] := PByteArray(Pointer(@I))^[0];
  Result := PInteger(@ABuffer)^;
end;

class function GSFile.BSwap16(I: WORD): WORD;
var
  ABuffer: array[0..2] of Byte;
begin
  //XCHG    AL,AH
  ABuffer[0] := PByteArray(Pointer(@I))^[1];
  ABuffer[1] := PByteArray(Pointer(@I))^[0];
  Result := PWord(@ABuffer)^;
end;

class function GSFile.BSwap64(I: UInt64): UInt64;
asm
  MOV     EDX,[EAX]
  MOV     EAX,[EAX+4]
  BSWAP   EAX
  BSWAP   EDX
end;

function GSFile.IntToBin(p_nb_int: uint64; p_nb_digits: byte=64): string;
begin
  SetLength(Result, p_nb_digits);
  while p_nb_digits > 0 do
  begin
    if odd(p_nb_int) then
      Result[p_nb_digits] := '1'
    else
      Result[p_nb_digits] := '0';
    p_nb_int := p_nb_int shr 1;
    dec(p_nb_digits);
  end;
end;

function GSFile.Open(AFileName: string): Boolean;
begin
  FFile := TFileStream.Create(AFileName, fmOpenRead);
  FFileBitReader := TBitReader.Create(FFile, boBigEndian);
end;

procedure GSFile.AddLog(AClassName: string; AValueCount: Integer);
var
  AText: string;
begin
  NotePad.AddLog(AClassName, AValueCount, FFile.Position);
end;

//==============================================================================

constructor TNotepad.Create;
begin
  FStrings := TStringList.Create(False);
  DoLogging := False;
  FCounter := 1;
end;


procedure TNotepad.StartLogging;
begin
  DoLogging := True;
end;

procedure TNotepad.Add(const S: string);
begin
  FStrings.Add(S);
end;

procedure TNotepad.AddLog(AClassName: string; AValueCount, AFilePos: Int64);
begin
  Add(
    '#' + IntToStr(FCounter) + '. ' +
    AClassName + '   ValueCount = ' + IntToStr(AValueCount) + '    FilePos = ' +
    IntToStr(AFilePos));
  Inc(FCounter);
end;

procedure TNotepad.AddList(AName: string; AList: TList<Integer>; ALimit: Integer);
var
  i: Integer;
  AText: string;
begin
  AddBreak;
  Add(AName + ' : (' + IntToStr(AList.Count) + ')');
  AText := '';
  for i := 0 to AList.Count - 1 do
  begin
    if (AText <> '') then
      AText := AText + ', ';
    AText := AText + IntToStr(AList[i]);
    if (ALimit > 0) and (i >= ALimit) then
      Break;
  end;
  Add(AText);
end;

procedure TNotepad.AddList(AName: string; AList: TList<UInt64>; ALimit: Integer);
var
  i: Integer;
  AText: string;
begin
  AddBreak;
  Add(AName + ' : (' + IntToStr(AList.Count) + ')');
  AText := '';
  for i := 0 to AList.Count - 1 do
  begin
    if (AText <> '') then
      AText := AText + ', ';
    AText := AText + IntToStr(AList[i]);
    if (ALimit > 0) and (i >= ALimit) then
      Break;
  end;
  Add(AText);
end;

procedure TNotepad.AddList(AName: string; AList: TList<Single>; ALimit: Integer);
var
  i: Integer;
  AText: string;
begin
  AddBreak;
  Add(AName + ' : (' + IntToStr(AList.Count) + ')');
  AText := '';
  for i := 0 to AList.Count - 1 do
  begin
    if (AText <> '') then
      AText := AText + ', ';
    AText := AText + FloatToStr(AList[i]);
    if (ALimit > 0) and (i >= ALimit) then
      Break;
  end;
  Add(AText);
end;

procedure TNotepad.AddBreak();
begin
  Add('-----------------');
end;

function TNotepad.GetText;
begin
  Result := FStrings.Text;
end;

procedure TNotepad.SaveToFile(APath: string);
begin
  FStrings.SaveToFile(APath);
end;

procedure TNotepad.SetText(const S: string);
begin
  FStrings.Text := S;
end;

//==============================================================================

procedure Mix(var a, b, c: Cardinal);
begin
  a := a - b; a := a - c; a := a xor (c shr 13);
  b := b - c; b := b - a; b := b xor (a shl 8);
  c := c - a; c := c - b; c := c xor (b shr 13);
  a := a - b; a := a - c; a := a xor (c shr 12);
  b := b - c; b := b - a; b := b xor (a shl 16);
  c := c - a; c := c - b; c := c xor (b shr 5);
  a := a - b; a := a - c; a := a xor (c shr 3);
  b := b - c; b := b - a; b := b xor (a shl 10);
  c := c - a; c := c - b; c := c xor (b shr 15);
end;

function Hash(P: PShortIntArray; ALength, AHash: Cardinal): Cardinal;
var
  A, B, C, Len: Cardinal;
  procedure Mix;
  begin
    a := a - b; a := a - c; a := a xor (c shr 13);
    b := b - c; b := b - a; b := b xor (a shl 8);
    c := c - a; c := c - b; c := c xor (b shr 13);
    a := a - b; a := a - c; a := a xor (c shr 12);
    b := b - c; b := b - a; b := b xor (a shl 16);
    c := c - a; c := c - b; c := c xor (b shr 5);
    a := a - b; a := a - c; a := a xor (c shr 3);
    b := b - c; b := b - a; b := b xor (a shl 10);
    c := c - a; c := c - b; c := c xor (b shr 15);
  end;
begin
  { Set up the internal state }
  Len := ALength;
  a := $9E3779B9;   // the golden ratio; an arbitrary value
  b := a;
  c := AHash;      // the previous hash value
  { handle most of the }
  while (len >= 12) do
  begin
    A := A + (Cardinal(P[0]) + (Cardinal(P[1]) shl 8) + (Cardinal(P[2])  shl 16) + (Cardinal(P[3])  shl 24));
    B := B + (Cardinal(P[4]) + (Cardinal(P[5]) shl 8) + (Cardinal(P[6])  shl 16) + (Cardinal(P[7])  shl 24));
    C := C + (Cardinal(P[8]) + (Cardinal(P[9]) shl 8) + (Cardinal(P[10]) shl 16) + (Cardinal(P[11]) shl 24));
    Mix;
    P := Pointer(Cardinal(P) + 12);
    Len := Len - 12;
  end;

  { handle the last 11 bytes }
  C := C + ALength;
  case (Len) of   // all the case statements fall through
    11: c := c + (Cardinal(P[10]) shl 24);
    10: c := c + (Cardinal(P[9]) shl 16);
    9 : c := c + (Cardinal(P[8]) shl 8);
    { the first byte of c is reserved for the length }
    8 : b := b + (Cardinal(P[7]) shl 24);
    7 : b := b + (Cardinal(P[6]) shl 16);
    6 : b := b + (Cardinal(P[5]) shl 8);
    5 : b := b + P[4];
    4 : a := a + (Cardinal(P[3]) shl 24);
    3 : a := a + (Cardinal(P[2]) shl 16);
    2 : a := a + (Cardinal(P[1]) shl 8);
    1 : a := a + P[0];
  end;
  Mix;

  Result := C;
end;

function Hash3(k: PWordArray; length: Cardinal; initval: Cardinal): Cardinal;
var
  a, b, c, len: Cardinal;
begin
  { Set up the internal state }

  len := length;
  a := $9E3779B9; // the golden ratio; an arbitrary value
  b := a;
  c := initval;   // the previous hash value

  while (len >= 6) do
  begin
    a := a + (k[0] + (Cardinal(k[1]) shl 16));
    b := a + (k[2] + (Cardinal(k[3]) shl 16));
    c := c + (k[4] + (Cardinal(k[5]) shl 16));
    Mix(a, b, c);
    k := Pointer(Cardinal(k) + 6);
    len := len - 6;
  end;

  { handle the last 2 uint32s }

  c := c + length;
  case (len) of                           // all the case statements fall through */
    5: c := c + (Cardinal(k[4]) shl 16);
    { c is reserved for the length }
    4: b := b + (Cardinal(k[3]) shl 16);
    3: b := b + k[2];
    2: a := a + (Cardinal(k[1]) shl 16);
    1: a := a + k[0];
  end;
  Mix(a, b, c);

  Result := c;
end;

function Hash32(APointer: Pointer; ACount: Integer; AHash: Cardinal): Cardinal;
begin
  if (ACount = 0) then
    Exit(AHash);
  Result := Hash(APointer, ACount * 4, AHash);
end;

function Hash16(APointer: Pointer; ALength: Integer; AHAsh: Cardinal): Cardinal;
begin
  if (ALength = 0) then
    Exit(AHash);
  Result := Hash3(APointer, ALength, AHash);
end;

end.
