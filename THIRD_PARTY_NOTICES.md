# Third-Party Notices

Sonora depends on
[SFBAudioEngine 0.13.0](https://github.com/sbooth/SFBAudioEngine), distributed
under the MIT License.

SFBAudioEngine includes or links codec libraries under their respective
licenses, including FLAC, Ogg, Vorbis, mpg123, libsndfile, TagLib, and related
components. The authoritative license texts are provided by the resolved
Swift package under SFBAudioEngine's `LICENSES` directory and must accompany
distributed builds of Sonora.

Some transitive components use the LGPL and must remain dynamically linked.
Release packaging must preserve the bundled dynamic frameworks and their
license notices.
