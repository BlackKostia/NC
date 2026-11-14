# Extended Modal Dialog Classes (included by classes.inc)

CLASS_BEGIN ConflictDialog
    EXTENDS Dialog
    FIELD ConflictDialog.action,   4
    FIELD ConflictDialog.for_all,  4
    FIELD ConflictDialog.src_size, 8
    FIELD ConflictDialog.dst_size, 8
    FIELD ConflictDialog.name,     NAME_MAX
CLASS_END ConflictDialog

CLASS_BEGIN SearchDialog
    EXTENDS Dialog
    FIELD SearchDialog.focus_field, 4   # 0=name mask, 1=content grep
    FIELD SearchDialog.name_len,    4
    FIELD SearchDialog.grep_len,    4
    FIELD SearchDialog.pad,         4
    FIELD SearchDialog.name_buf,    128
    FIELD SearchDialog.grep_buf,    128
CLASS_END SearchDialog

CLASS_BEGIN ChmodDialog
    EXTENDS Dialog
    FIELD ChmodDialog.mode,        4
    FIELD ChmodDialog.uid,         4
    FIELD ChmodDialog.gid,         4
    FIELD ChmodDialog.cursor,      4
    FIELD ChmodDialog.owner_len,   4
    FIELD ChmodDialog.edit_owner,  4
    FIELD ChmodDialog.owner_buf,   32
    FIELD ChmodDialog.target_path, PATH_MAX
CLASS_END ChmodDialog

CLASS_BEGIN InfoDialog
    EXTENDS Dialog
    FIELD InfoDialog.crc32,        4
    FIELD InfoDialog.hash_ok,      4
    FIELD InfoDialog.st,           FileStat._size
    FIELD InfoDialog.sha_hex,      68
    FIELD InfoDialog.target_path,  PATH_MAX
CLASS_END InfoDialog

CLASS_BEGIN FuzzyDialog
    EXTENDS Dialog
    FIELD FuzzyDialog.mode,        4   # 0=Command Palette, 1=Fuzzy Finder
    FIELD FuzzyDialog.query_len,   4
    FIELD FuzzyDialog.cursor,      4
    FIELD FuzzyDialog.scroll,      4
    FIELD FuzzyDialog.total_cnt,   4
    FIELD FuzzyDialog.match_cnt,   4
    FIELD FuzzyDialog.items_ptr,   8   # { char *label (8), uint32_t score (4), uint32_t payload (4) }
    FIELD FuzzyDialog.pool_ptr,    8   # string pool for Fuzzy Finder paths
    FIELD FuzzyDialog.matches_ptr, 8   # { uint32_t item_idx (4), int32_t score (4), uint64_t mask (8) }
    FIELD FuzzyDialog.query_buf,   128
    FIELD FuzzyDialog.base_path,   PATH_MAX
CLASS_END FuzzyDialog
