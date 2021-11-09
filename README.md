# Delphi-JT-Loader

The following classes and records can be used to load the complex Siemens JT File Format. The files actually didn't require any DLL to run, except the Version 10, where Siemens suddenly decided to apply LibLZMA compression. That's why there is one DLL added to the repository. However. The rest of the code is fully native, so it will give you a good overview of how the Siemens JT format was translated to Delphi.

I have tested the format with JT Versions 8.1 up to 10.5 with success. However. You need some units from my other project "CORE Engine" to be able to fully use these units here. You can find those at 

https://github.com/Arsanias/Delphi-Core-Engine

## System Requirements

* Windows x86 Computer
* DirectX or OpenGL compatible Graphics Card

## Current Issues

* The loader units are powerful enough to let you read any of the JT segments. However, the example units just show you how to read the solid CAD mesh. Properties are ignored. You may have a look at the attached JT Specifications for further info about what kind of data can be found in which segment.
* The Test Project merely loads a file but does not automatically display it. You have to expand each branch and double-click the related solid to display it. Each solid has to individually activated with a double-click to be visible on the scene.
* The Siemens JT Specification does not show you how exactly the solid hierarchy has to be build in a tree. It is a painful process to create the correct hierarchy. I made some trials to find the best setup. However. If you should detect an error and have a proposal for an improvement, then just put me a message.
* On complex models with various instances of the same Mesh, each instance has a different position or orientation. The matrix for that transformation is stored inside the structure and can be loaded. Unfortunately I had no time to complete this, so you have to do it yourself (or load only simple models). :)
