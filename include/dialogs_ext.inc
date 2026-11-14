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
