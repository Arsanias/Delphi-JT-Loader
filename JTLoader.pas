// Copyright (c) 2021 Arsanias
// Distributed under the MIT software license, see the accompanying
// file LICENSE or http://www.opensource.org/licenses/mit-license.php.

unit
  JTLoader;

interface

uses
  System.SysUtils, System.StrUtils, System.Variants, System.Types, System.ZLib,
  System.Classes, System.Math,
  Vcl.Dialogs,
  Generics.Defaults, Generics.Collections,
  Core.Utils, Core.Types, Core.Material, Core.Mesh, Core.Model, Core.ByteReader, Core.Loader,
  JTFormat, JTMesh;

const
  DefaultColor: TVector4 = (R:0.5; G:0.5; B:0.5; A:1.0);

type
  JTFile = class(TCoreLoader)
  private
    EntryCount: Int32;
    TOCEntries: array of TTOCEntry;
    FDataSegments: TList<TDataSegment>;
    FileHeader: TFileHeader;
    FLSGSegment: TLSGSegment;
    procedure ReadLSGSegment;
    procedure ReadTOCEntries;
    procedure TranslateTriStripShape(AModel: TModel; TriStripSetShapeLODElement: TTriStripSetShapeLODElement);
  public
    Model: TModel;
    constructor Create;
    destructor Destroy; override;
    function Open(AFileName: string): Boolean; override;
    procedure ReadDataSegments(ASegmentID: TGUID);
    procedure Translate;
    property ByteBuffer: TByteReader read FByteBuffer;
    property DataSegments: TList<TDataSegment> read FDataSegments;
    property LSGSegment: TLSGSegment read FLSGSegment;
  end;

var
  TOCEntries: array of TTOCEntry;

implementation

uses
  JTCodec;

constructor JTFile.Create;
var
  i: Integer;
begin
  inherited;

  FFile := nil;
  FileHeader := nil;
  FLSGSegment := nil;
  FDataSegments := TList<TDataSegment>.Create;
end;

destructor JTFile.Destroy;
var
  i: Integer;
  TOCEntry: TTOCEntry;
begin
  SafeFree(FFile);

  for TOCEntry in TOCEntries do
    TOCEntry.Free;

  for i := 0 to FDataSegments.Count - 1 do
    if FDataSegments[i] <> nil then FDataSegments[i].Free;
  FDataSegments.Free;

  SafeFree(FLSGSegment);
  SafeFree(Model);

  if FileHeader <> nil then
    FileHeader.Free;

  inherited;
end;

procedure JTFile.ReadLSGSegment;
var
  i: Integer;
begin
  for i := 0 to Length(TOCEntries) - 1 do
    if (TOCEntries[i].SegmentID = FileHeader.LSGSegmentID) then
    begin
      FLSGSegment := TLSGSegment.Create(Self, TOCEntries[i].SegmentOffset);
      Exit;
    end;
  raise Exception.Create('LSG Segment not found.');
end;

procedure JTFile.ReadTOCEntries;
var
  i: Integer;
begin
  EntryCount := Read32;
  SetLength(TOCEntries, EntryCount);

  for i := 0 to EntryCount - 1 do
    TOCEntries[i] := TTOCEntry.Create(Self);
end;

procedure JTFile.ReadDataSegments(ASegmentID: TGUID);
var
  i: Integer;
  ATOCEntry: TTOCEntry;
begin
  if EntryCount = 0 then Exit;

  for i := 0 to EntryCount - 1 do
  begin
    ATOCEntry := TOCEntries[i];

    if (ATOCEntry.SegmentID = ASegmentID) then
      FDataSegments.Add(TShapeLODSegment.Create(Self, ATOCEntry.SegmentOffset));
  end;
end;

function JTFile.Open(AFileName: string): Boolean;
var
  i: Integer;
  AVersion: Single;
begin
  inherited Open(AFileName);

  Result := False;
  if Assigned(FFile) then
  begin
    try
      FileHeader := TFileHeader.Create(Self, AVersion);
      FFileVersion := AVersion;

      ReadTOCEntries;
      ReadLSGSegment;
    finally
      //NotePad.SaveToFile('C:\Users\akaragm\Documents\RAD Studio\Projekte\JT Viewer\Log.txt');
    end;
  end;
end;

procedure JTFile.Translate;
var
  i: Integer;
  DataSegment: TDataSegment;
begin
  { create model and mesh }

  Model := TModel.Create('JT Import', True);
  for i := 0 to FDataSegments.Count - 1 do
  begin
    if FDataSegments[i].ClassType = TShapeLODSegment then
        TranslateTriStripShape(Model, TShapeLODSegment(FDataSegments[i]).Element as TTriStripSetShapeLODElement);
  end;
end;

procedure JTFile.TranslateTriStripShape(AModel: TModel; TriStripSetShapeLODElement: TTriStripSetShapeLODElement);
var
  VertexShapeLODElement: TVertexShapeLODElement;
  VertexBasedShapeCompressedRepData: TVertexBasedShapeCompressedRepData;
  TopoCompVertexRecs: TTopologicallyCompressedVertexRecords;
  SourceVertices: TList<Single>;
  SourceNormals: TList<Single>;
  SourceColors: TList<Single>;
  ListIndices: TList<Integer>;
  StartIndex: Integer;
  EndIndex: Integer;
  vertexIndicesList: TList<Integer>;
  normalIndicesList: TList<Integer>;
  lastNormalIndex: Integer;
  BaseIndex: Integer;
  fi1, fi2, fi3: Integer; // Face Index
  ni1, ni2, ni3: Integer; // Normal Index
  MeshDecoder: TMeshDecoder;
  i, j, k, l, rc: Integer;
  AMesh: TMesh;
  vc, nc: Integer;
begin
  if TriStripSetShapeLODElement = nil then Exit;
  if AModel = nil then Exit;

  if ((FileVersion >= 8.0) and (FileVersion < 9.0)) then
  begin
    AMesh := TMesh.Create('Face ' + IntToStr(AModel.Meshes.Count + 1), TVertexTopology.ptTriangleStrip, TGX_ShadeMode.smFlat, [asPosition, asNormal]);

    { norminate source arrays }

    VertexBasedShapeCompressedRepData := TriStripSetShapeLODElement.VtexBasedShapeComprRepData;

    SourceVertices := VertexBasedShapeCompressedRepData.Vertices;
    SourceNormals := VertexBasedShapeCompressedRepData.Normals;
    SourceColors := VertexBasedShapeCompressedRepData.Colors;
    ListIndices := VertexBasedShapeCompressedRepData.PrimitiveListIndices;

    if ((SourceVertices = nil) or (SourceVertices.Count = 0)) then
      raise Exception.Create('TranslateTriStripShape'#13 + 'No vertices found');

    { calculate the array requirement }

    j := 0; k := 0;
    for i := 0 to ListIndices.Count - 2 do
    begin
      StartIndex := ListIndices[i];
      EndIndex := ListIndices[i + 1];
      Inc(j, endIndex - startIndex);
      Inc(k, endIndex - startIndex - 2);
    end;

    rc := AModel.Vertices.RowCount;
    AModel.Vertices.RowCount := AModel.Vertices.RowCount + j;
    AModel.Normals.RowCount := AModel.Normals.RowCount + j ;
    AMesh.Faces.RowCount := k * 3;

    l := 0;
    for i := 0 to ListIndices.Count - 2 do
    begin
      StartIndex := ListIndices[i];
      EndIndex := ListIndices[i + 1];

      { add vertices and normals }

      for j := startIndex to endIndex - 1 do
      begin
        k := j * 3;
        AModel.Vertices[0].AsFloat3[rc + j] := TVector3.Create(SourceVertices[k], SourceVertices[k + 1], SourceVertices[k + 2]);
        AModel.Normals[0].AsFloat3[rc + j] := TVector3.Create(SourceNormals[k], SourceNormals[k + 1], SourceNormals[k + 2]);
      end;

      { faces }

      SetLength(AMesh.Stripes, Length(AMesh.Stripes) + 1);
      AMesh.Stripes[Length(AMesh.Stripes) - 1].Count := (EndIndex - StartIndex - 2) * 3;
      AMesh.Stripes[Length(AMesh.Stripes) - 1].StartLocation := l;

      for j := startIndex to (endIndex - 2) - 1 do
      begin
        AMesh.Faces[asPosition].AsInteger[l]:= rc + j;
        AMesh.Faces[asPosition].AsInteger[l+1]:= rc + j + 1;
        AMesh.Faces[asPosition].AsInteger[l+2]:= rc + j + 2;

        AMesh.Faces[asNormal].AsInteger[l]:= rc + j;
        AMesh.Faces[asNormal].AsInteger[l+1]:= rc + j + 1;
        AMesh.Faces[asNormal].AsInteger[l+2]:= rc + j + 2;

        Inc(l, 3);
      end;
    end;

    { colors }

    if ((SourceColors <> nil) and (SourceColors.Count > 0)) then
      for i := 0 to SourceColors.Count - 1 do
        AModel.AddColor(TVector4.Create(SourceColors[i * 3], SourceColors[i * 3 + 1], SourceColors[i * 3 + 2], 1.0));
  end
  else
  if ((FileVersion >= 9.0) and (FileVersion < 11.0)) then
  begin
    VertexShapeLODElement := TriStripSetShapeLODElement;
    TopoCompVertexRecs := VertexShapeLODElement.TopoMeshTopologicallyCompressedLODData.TopologicallyCompressedRepData.TopologicallyCompressedVertexRecords;

    SourceVertices := TopoCompVertexRecs.Vertices;
    SourceNormals := TopoCompVertexRecs.Normals;
    SourceColors := nil;
    if TopoCompVertexRecs.ColorArray <> nil then
      SourceColors := TopoCompVertexRecs.ColorArray.ColorValues;

    MeshDecoder := TMeshDecoder.Create(VertexShapeLODElement.TopoMeshTopologicallyCompressedLODData.TopologicallyCompressedRepData);
    MeshDecoder.Decode;

    if ((SourceVertices = nil) or (SourceVertices.Count = 0) or (MeshDecoder.VertexIndices.Count = 0)) then
      raise Exception.Create('TranslateTriStripShape:'#13 + 'No vertices found');

    AMesh := TMesh.Create('Face ' + IntToStr(AModel.Meshes.Count + 1), TVertexTopology.ptTriangles, TGX_ShadeMode.smFlat, [asPosition, asNormal]);

    VertexIndicesList := MeshDecoder.VertexIndices;
    NormalIndicesList := MeshDecoder.NormalIndices;

    { vertices and normals }

    LastNormalIndex := -1;
    AMesh.Faces.RowCount := VertexIndicesList.Count;

    rc := Model.Vertices.RowCount;
    Model.Vertices.RowCount := rc + VertexIndicesList.Count;
    Model.Normals.RowCount := rc + VertexIndicesList.Count;

    vc := rc; nc := rc;
    for i := 0 to VertexIndicesList.Count div 3 - 1 do
    begin
      BaseIndex := (i * 3);

      fi1 := VertexIndicesList[BaseIndex];
      fi2 := VertexIndicesList[BaseIndex + 1];
      fi3 := VertexIndicesList[BaseIndex + 2];

      ni1 := NormalIndicesList[BaseIndex];
      ni2 := NormalIndicesList[BaseIndex + 1];
      ni3 := NormalIndicesList[BaseIndex + 2];

      if ni1 = -1 then ni1 := LastNormalIndex;
      LastNormalIndex := ni1;
      if ni2 = -1 then ni2 := LastNormalIndex;
      LastNormalIndex := ni2;
      if ni3 = -1 then ni3 := LastNormalIndex;
      LastNormalIndex := ni3;

      AMesh.Faces[asPosition].AsInteger[BaseIndex] := rc + BaseIndex;
      AMesh.Faces[asPosition].AsInteger[BaseIndex + 1] := rc + BaseIndex + 1;
      AMesh.Faces[asPosition].AsInteger[BaseIndex + 2] := rc + BaseIndex + 2;
      AMesh.Faces[asNormal].AsInteger[BaseIndex] := rc + BaseIndex;
      AMesh.Faces[asNormal].AsInteger[BaseIndex + 1] := rc + BaseIndex + 1;
      AMesh.Faces[asNormal].AsInteger[BaseIndex + 2] := rc + BaseIndex + 2;

      AModel.Vertices[0].AsFloat3[vc] := TVector3.Create(SourceVertices[fi1 * 3], SourceVertices[fi1 * 3 + 1], SourceVertices[fi1 * 3 + 2]); Inc(vc);
      AModel.Vertices[0].AsFloat3[vc] := TVector3.Create(SourceVertices[fi2 * 3], SourceVertices[fi2 * 3 + 1], SourceVertices[fi2 * 3 + 2]); Inc(vc);
      AModel.Vertices[0].AsFloat3[vc] := TVector3.Create(SourceVertices[fi3 * 3], SourceVertices[fi3 * 3 + 1], SourceVertices[fi3 * 3 + 2]); Inc(vc);

      AModel.Normals[0].AsFloat3[nc] := TVector3.Create(SourceNormals[ni1 * 3], SourceNormals[ni1 * 3 + 1], SourceNormals[ni1 * 3 + 2]); Inc(nc);
      AModel.Normals[0].AsFloat3[nc] := TVector3.Create(SourceNormals[ni2 * 3], SourceNormals[ni2 * 3 + 1], SourceNormals[ni2 * 3 + 2]); Inc(nc);
      AModel.Normals[0].AsFloat3[nc] := TVector3.Create(SourceNormals[ni3 * 3], SourceNormals[ni3 * 3 + 1], SourceNormals[ni3 * 3 + 2]); Inc(nc);
    end;

    { colors }

    if ((SourceColors <> nil) and (SourceColors.Count > 0)) then
      for i := 0 to SourceColors.Count - 1 do
        AModel.AddColor(TVector4.Create(SourceColors[i * 3], SourceColors[i * 3 + 1], SourceColors[i * 3 + 2], 1.0));

    MeshDecoder.Free;
  end;

  AMesh.Material := TGX_Material.Create;
  AModel.Materials.Add(AMesh.Material);
  AMesh.Material.AmbientColor := DefaultColors[AModel.Meshes.Count];
  AMesh.Indexed := True;
  AModel.Meshes.Add(AMesh);
end;

end.
