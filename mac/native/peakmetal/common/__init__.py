"""Unity 6000.3 Shader codec shared by the graphics and compute converters.

binio   little-endian reader/writer      blob    per-platform blob container (segments/entries)
program program entries + Metal/Vulkan program data      params  parameter entries (all binding kinds)
shader  typetree-level helpers (platform blobs <-> Shader fields)   smolv  pure-Python SMOL-V decoder
"""
