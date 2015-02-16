rtl_fm-scanner
==============
This is a websocket interface to rtl_fm (part of RTL-SDR).

Dependencies
------------

* A version of rtl_fm that outputs file for each transmission.  At time of creating rtl_fm-scanner this capability did not exist in stock version.
* Front end (cart_console).  This application has no user unterface on its own.
* Mojolicious
* SQLite (and frequency database in data directory)
* Modules/Plugins
  * DBIx::Connector to access SQLite
  * Mojolicious::Plugin::RenderFile
  * Mojolicious::Plugin::CORS to address same origin policy in browsers

Note
----
In its current state rtl-fm_scanner is not intended for general use.  In fact it may never reach that point.

