// Copyright (c) 2021 Arsanias
// Distributed under the MIT software license, see the accompanying
// file LICENSE or http://www.opensource.org/licenses/mit-license.php.

unit
  TestUnit;

interface

uses
  Winapi.Windows, Winapi.Messages, Winapi.CommCtrl,
  System.SysUtils, System.Variants, System.Classes, System.Types, System.Generics.Collections, System.Math,
  System.TypInfo, System.StrUtils,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls, Vcl.ImgList,
  Core.Utils, Core.Types, Core.Mesh, Core.RenderDevice, Core.ShaderDX, Core.RenderDeviceDX,
  Core.Camera, Core.Light, Core.Cast,
  JTLoader;

type
  TForm1 = class(TForm)
    Panel1: TPanel;
    Button1: TButton;
    OpenDialog1: TOpenDialog;
    AutoDisplayBox: TCheckBox;
    RenderPanel: TPanel;
    Splitter1: TSplitter;
    Timer1: TTimer;
    Label1: TLabel;
    PageControl1: TPageControl;
    ExplorerSheet: TTabSheet;
    ElementsSheet: TTabSheet;
    ElementsGrid: TTreeView;
    ExplorerGrid: TTreeView;
    GridImages: TImageList;
    ImageList1: TImageList;
    PropertyGrid: TTreeView;
    Splitter2: TSplitter;
    procedure Button1Click(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure Timer1Timer(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure AtomGridDblClick(Sender: TObject);
    procedure ExplorerGridDblClick(Sender: TObject);
    procedure PropertyGridCompare(Sender: TObject; Node1, Node2: TTreeNode; Data: Integer; var Compare: Integer);
    procedure ElementsGridClick(Sender: TObject);
  private
    FDevice: TRenderDevice;
    FCast: TCast;
    FCamera: TCamera;
    FLight: TLight;
    FFile: JTFile;
    Frequency: Int64;
    PiCounter: Single;
    MasterScale: TVector3;
    procedure UpdateElementsGrid;
    procedure UpdatePropertyTableGrid;
    procedure UpdateObjectInspector;
    procedure ShowModel;
  end;

var
  Form1: TForm1;

implementation
  {$R *.dfm}

uses
  JTFormat, JTCodec, JTMesh, Core.ByteReader, Core.Loader;

procedure TForm1.AtomGridDblClick(Sender: TObject);
var
  AObjectID: Integer;
  AProperty: TBasePropertyAtomElement;
  ALateLoadedProperty: TLateLoadedPropertyAtomElement;
begin
  if (ElementsGrid.Selected.Level = 0) then
  begin
    AObjectID := Integer(ElementsGrid.Selected.Data);
    if FFile.LSGSegment.FindElement(AObjectID, TBaseElement(AProperty)) then

    if (AProperty.ClassType = TLateLoadedPropertyAtomElement) then
    begin
      ALateLoadedProperty := TLateLoadedPropertyAtomElement(AProperty);
      FFile.ReadDataSegments(ALateLoadedProperty.SegmentID);
      if (FFile.DataSegments.Count > 0) then
        ShowModel;
    end;
  end;
end;

procedure TForm1.Button1Click(Sender: TObject);
begin
  if FFile <> nil then
    FreeAndNil(FFile);

  FFile := JTFile.Create;
  if OpenDialog1.Execute and (OpenDialog1.Files.Count > 0) then
  begin
    try
      FFile.Open(OpenDialog1.Files[0]);

      UpdateElementsGrid;
      UpdatePropertyTableGrid;
      UpdateObjectInspector;

      if AutoDisplayBox.Checked then
      begin
        FFile.ReadDataSegments(UnknownElementID);
        ShowModel;
      end;
    except
      on E: Exception do
      begin
        Application.ShowException(E);
        Exit;
      end;
    end;
  end;
end;

procedure TForm1.ElementsGridClick(Sender: TObject);
var
  i: Integer;
begin
  if ElementsGrid.Selected = nil then Exit;

  PropertyGrid.FullCollapse;

  for i := 0 to PropertyGrid.Items.Count - 1 do
    if (Integer(PropertyGrid.Items[i].Data) = TBaseElement(ElementsGrid.Selected.Data).ObjectID) then
    begin
      PropertyGrid.Items[i].Selected := True;
      PropertyGrid.Items[i].Expand(False);
      PropertyGrid.Selected.MakeVisible;
      Break;
    end;
end;

procedure TForm1.ExplorerGridDblClick(Sender: TObject);
var
  ANode: TTreeNode;
  AElement: TBaseElement;
  AShapeElement: TTriStripSetShapeNodeElement;
  AGUID: TGUID;
begin
  ANode := ExplorerGrid.Selected;
  if ANode = nil then Exit;

  AElement := TBaseElement(ANode.Data);

  // An Instance Node Element has no children group and would cause an exception
  // when looking for a GroupNodeElement

  if AElement.InheritsFrom(TInstanceNodeElement) then
    FFile.LSGSegment.FindElement(TInstanceNodeElement(AElement).ChildNodeObjectID, AElement);

  while (AElement <> nil) do
  begin
    if (AElement.InheritsFrom(TTriStripSetShapeNodeElement)) then
    begin
      AShapeElement := TTriStripSetShapeNodeElement(AElement);

      if FFile.LSGSegment.GetLateLoadedSegmentID(AElement.ObjectID, JT_LSG_KEY_PROP_SHAPE, AGUID) then
      begin
        FFile.ReadDataSegments(AGUID);
        ShowModel;
      end;
      Break;
    end;
    FFile.LSGSegment.FindElement(TGroupNodeElement(AElement).ChildNodeObjectIDs[0], AElement);
  end;
end;

procedure TForm1.ShowModel;
var
  AScale: Single;
  ACenter: TVector3;
begin
  FFile.Translate;

  if (FDevice = nil) then
  begin
    FDevice := TGraphicsDeviceDX.Create(True, RenderPanel.Handle, RenderPanel.ClientRect);

    { Create Camera and set light }

    FCamera := TCamera.Create();
    FLight := TLight.Create();

    FLight.Intensity := 0.5;
    FLight.Direction := TVector3.Create(0.6, 0.3, -0.1);

    FDevice.MainConst.FLightDir := TVector4.Create(FLight.Direction);
    FDevice.MainConst.FCameraPos := TVector4.Create(FCamera.Position);
  end;

  FCast := TCast.Create(FFile.Model, 'Test');

  FCast.Model.UpdateSize;

  ACenter := FCast.Model.MaxSize - (FCast.Model.Size / 2);
  FCast.Model.Center := ACenter;
  FCast.Position := FCast.Position - ACenter;

  AScale := 3 / FCast.Model.Size.Magnitude;
  FCast.Scale := TVector3.Create(AScale, AScale, AScale);

  PiCounter := 0;
  MasterScale := FCast.Scale;

  QueryPerformanceFrequency(Frequency);

  FCast.Prepare(FDevice);
  Timer1Timer(Timer1);
  Timer1.Enabled := True;
end;

procedure TForm1.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  Timer1.Enabled := False;
end;

procedure TForm1.FormCreate(Sender: TObject);
begin
  FFile := nil;
  FDevice := nil;
  FCamera := nil;
  FLight := nil;
end;

procedure TForm1.FormDestroy(Sender: TObject);
var
  i: Integer;
begin
  SafeFree(FFile);

  if FCast <> nil then
    for i := 0 to FCast.Childs.Count -1 do
      FCast.Childs[i].Free;
  FCast.Free;

  if FDevice <> nil then
  begin
    FDevice.Free;
    FCamera.Free;
    FLight.Free;
  end;
end;

procedure TForm1.PropertyGridCompare(Sender: TObject; Node1, Node2: TTreeNode; Data: Integer; var Compare: Integer);
begin
  if Integer(Node1.Data) > Integer(Node2.Data) then
    Compare := 1
  else
  if Integer(Node1.Data) < Integer(Node2.Data) then
    Compare := -1
  else
    Compare := 0;
end;

procedure TForm1.Timer1Timer(Sender: TObject);
var
  Start, Stop: Int64;
  ScaleFactor: Single;
begin
  QueryPerformanceCounter(Start);

  FDevice.ClearScene();
  FCast.Render(FDevice, FCamera);
  FDevice.Show;

  QueryPerformanceCounter(Stop);
  Label1.Caption := FormatFloat('0.000', (Stop - Start) * 1000 / Frequency) + ' ms';

  FCast.Rotation := TVector3.Create(FCast.Rotation.X + 0.01, FCast.Rotation.Y + 0.01, FCast.Rotation.Z + 0.01);

  ScaleFactor := 0.5 + Sin(PiCounter);
  FCast.Scale := MasterScale * ScaleFactor;

  PiCounter := PiCounter + 0.01;
  if PiCounter >= PI then
    PiCounter := PiCounter - PI;
end;

procedure TForm1.UpdateObjectInspector;
type
  PIntegerDynArray = ^TIntegerDynArray;
var
  LSGSegment: TLSGSegment;
  AElement: TBaseElement;
  AText: string;
  AParentNode: TTreeNode;

  procedure AddNode(ADestParent, AElementsNode: TTreeNode);
  var
    ADestNode: TTreeNode;
  begin
    if (AElementsNode = nil) then
      Exit;

    ADestNode := nil;

    while (AElementsNode <> nil) do
    begin
      if (TBaseElement(AElementsNode.Data).ObjectID >= LSGSegment.PropertyStartIndex) then
        Break;

      AText := LSGSegment.GetPropertyValue(TBaseElement(AElementsNode.Data).ObjectID, JT_LSG_KEY_PROP_NAME);
      if (AText <> '') then
      begin
        ADestNode := ExplorerGrid.Items.AddChild(ADestParent, GetDelimetedStr(AText, 0, '.'));
        if (Pos('.part', AText) > 0) then
          ADestNode.ImageIndex := 1
        else
          ADestNode.ImageIndex := 0;
        ADestNode.SelectedIndex := ADestNode.ImageIndex;
        ADestNode.Data := AElementsNode.Data;
      end;

      if (ADestNode <> nil) then
        AddNode(ADestNode, AElementsNode.getFirstChild)
      else
        AddNode(ADestParent, AElementsNode.getFirstChild);

      AElementsNode := AElementsNode.getNextSibling;
    end;
  end;
begin
  ExplorerGrid.Items.Clear;
  AParentNode := ExplorerGrid.Items.Add(nil, 'Modell');

  LSGSegment := FFile.LSGSegment;

  ExplorerGrid.Items.BeginUpdate;
  try
    AddNode(AParentNode, ElementsGrid.Items.GetFirstNode);
  finally
    ExplorerGrid.Items.EndUpdate;
  end;
end;

procedure TForm1.UpdateElementsGrid;
var
  AElement: TBaseElement;
  ANode: TTreeNode;
  ALastObjectID: Integer;
  i, j: Integer;
begin
  ElementsGrid.Items.Clear;

  ANode := nil;
  ALastObjectID := -1;

  ElementsGrid.Items.BeginUpdate;
  try
    for i := 0 to FFile.LSGSegment.Elements.Count - 1 do
    begin
      AElement := FFile.LSGSegment.Elements[i];

      if (AElement = nil) or AElement.InheritsFrom(TBasePropertyAtomElement) then
        Break;

      if AElement.InheritsFrom(TBaseAttributeElement) then
        ElementsGrid.Items.AddChildObject(ANode, AElement.ToString, AElement)
      else
      if AElement.InheritsFrom(TBasePropertyAtomElement) then
        ElementsGrid.Items.AddObject(nil, AElement.ToString, AElement)
      else
      if AElement.InheritsFrom(TBaseNodeElement) then
      begin
        if ((AElement.ObjectID - ALastObjectID) = 1) or (AElement.ObjectID > ALastObjectID) then
        begin
          ANode := ElementsGrid.Items.AddChildObject(ANode, AElement.ToString, AElement);
          ALastObjectID := AElement.ObjectID;
        end
        else
        begin
          for j := 0 to ElementsGrid.Items.Count - 1 do
            if (TBaseElement(ElementsGrid.Items[j].Data).ObjectID = (AElement.ObjectID - 1)) then
            begin
              ANode := ElementsGrid.Items.AddObject(ElementsGrid.Items[j], AElement.ToString, AElement);
              Break;
            end;
        end;
      end;
    end;
  finally
    ElementsGrid.Items.EndUpdate;
  end;
end;

procedure TForm1.UpdatePropertyTableGrid;
var
  ALastID, i, j, k: Integer;
  APropertyTable: TNodePropertyTableList;
  ANode: TTreeNode;
  AKeyProperty, AValueProperty: TBasePropertyAtomElement;
  ALSGSEgment: TLSGSegment;
  AText: string;
begin
  PropertyGrid.Items.Clear;

  ALSGSegment := FFile.LSGSegment;
  if (ALSGSegment = nil) then Exit;

  PropertyGrid.Items.BeginUpdate;
  try
    ALastID := -1;
    for i := 0 to Length(FFile.LSGSegment.PropertyTable.NodePropertyTables) - 1  do
    begin
      APropertyTable := FFile.LSGSegment.PropertyTable.NodePropertyTables[i];

      for j := 0 to APropertyTable.Count - 1 do
      begin
        if (ALastID <> APropertyTable.NodeObjectID) then
          ANode := PropertyGrid.Items.AddObject(nil, 'ObjectID: ' + Format('%4d', [APropertyTable.NodeObjectID]), Pointer(APropertyTable.NodeObjectID));

        AKeyProperty := nil;
        AValueProperty := nil;

        for k := ALSGSegment.PropertyStartIndex to ALSGSegment.Elements.Count - 1 do
          if ALSGSegment.Elements[k].ObjectID = APropertyTable[j].KeyPropertyAtomObjectID then
          begin
            AKeyProperty :=  ALSGSegment.Elements[k] as TBasePropertyAtomElement;
            Break;
          end;

        for k := ALSGSegment.PropertyStartIndex to ALSGSegment.Elements.Count - 1 do
          if ALSGSegment.Elements[k].ObjectID = APropertyTable[j].ValuePropertyAtomObjectID then
          begin
            AValueProperty := ALSGSegment.Elements[k] as TBasePropertyAtomElement;
            Break;
          end;

        if (AKeyProperty <> nil) and (AValueProperty <> nil) then
        begin
          if (AKeyProperty.ClassType = TStringPropertyAtomElement) then
            AText := TStringPropertyAtomElement(AKeyProperty).Value + '  =  '
          else
            AText := '? = ';

          if (AValueProperty.ClassType = TStringPropertyAtomElement) then
            AText := AText + TStringPropertyAtomElement(AValueProperty).Value
          else
          if (AValueProperty.ClassType = TIntegerPropertyAtomElement) then
            AText := AText + IntToStr(TIntegerPropertyAtomElement(AValueProperty).Value)
          else
          if (AValueProperty.ClassType = TFloatingPointPropertyAtomElement) then
            AText := AText + FloatToStr(TFloatingPointPropertyAtomElement(AValueProperty).Value)
          else
          if (AValueProperty.ClassType = TDatePropertyAtomElement) then
            AText := AText + DateToStr(TDatePropertyAtomElement(AValueProperty).Date)
          else
          if (AValueProperty.ClassType = TLateLoadedPropertyAtomElement) then
            AText := AText + TLateLoadedPropertyAtomElement(AValueProperty).SegmentID.ToString;

          PropertyGrid.Items.AddChild(ANode, AText);
        end;

        ALastID := APropertyTable.NodeObjectID;
      end;
    end;

    PropertyGrid.AlphaSort(False);
  finally
    PropertyGrid.Items.EndUpdate;
  end;
end;

end.
