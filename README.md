# Delphi-JT-Loader

The following classes and records can be used to load the complex Siemens JT File Format. The files actually didn't require any DLL to run, except the Version 10, where Siemens suddenly decided to apply LibLZMA compression. That's why there is one DLL added to the repository. However. The rest of the code is fully native, so it will give you a good overview of how the Siemens JT format was translated to Delphi.

I have tested the format with JT Versions 8.1 up to 10.5 with success. However. You need some units from my other project "CORE Engine" to be able to fully use these units here. You can find those at 

https://github.com/Arsanias/Delphi-Core-Engine
