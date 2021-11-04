// Copyright (c) 2021 Arsanias
// Distributed under the MIT software license, see the accompanying
// file LICENSE or http://www.opensource.org/licenses/mit-license.php.

program JTViewer;

uses
  Vcl.Forms,
  TestUnit in 'TestUnit.pas' {Form1},
  GSLoader in 'GSLoader.pas',
  JTCodec in 'JTCodec.pas',
  JTFormat in 'JTFormat.pas',
  JTLoader in 'JTLoader.pas',
  JTMesh in 'JTMesh.pas',
  LibLZMA in 'LibLZMA.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TForm1, Form1);
  Application.Run;
end.
