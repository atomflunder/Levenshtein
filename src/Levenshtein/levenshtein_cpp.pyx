# distutils: language=c++
# cython: language_level=3
# cython: binding=True

from libc.stdint cimport uint32_t, uint8_t
from libc.stdlib cimport free
from libc.string cimport strlen
from cpython.list cimport PyList_New, PyList_SET_ITEM
from cpython.object cimport PyObject
from cpython.ref cimport Py_INCREF
from cpython.unicode cimport (
    PyUnicode_CompareWithASCIIString, PyUnicode_AS_UNICODE
)
from cpython.bytes cimport PyBytes_AS_STRING, PyBytes_FromStringAndSize
from cpython.sequence cimport PySequence_Check, PySequence_Length
from libc.stddef cimport wchar_t
from libcpp.vector cimport vector
from libcpp cimport bool
from libcpp.utility cimport move

from libcpp.algorithm cimport copy

from rapidfuzz.distance import (
    Editops as RfEditops,
    Opcodes as RfOpcodes
)
from rapidfuzz.distance.Levenshtein import (
    editops as rf_editops,
    opcodes as rf_opcodes
)

cdef extern from *:
    int PyUnicode_4BYTE_KIND

    object PyUnicode_FromWideChar(const wchar_t *w, Py_ssize_t size)
    unsigned int PyUnicode_KIND(object o)
    void* PyUnicode_DATA(object o)
    Py_UCS4 PyUnicode_READ(int kind, void *data, Py_ssize_t index)

    object PyUnicode_FromKindAndData(int kind, const void *buffer, Py_ssize_t size)

cdef extern from "<string>" namespace "std" nogil:
    cdef cppclass basic_string[T]:
        ctypedef size_t size_type

        basic_string() except +

        void resize(size_type) except +

        T& operator[](size_type)

        const T* data()
        size_type size()

cdef extern from "_levenshtein.hpp":
    void* safe_malloc(size_t nmemb, size_t size)

    ctypedef enum LevEditType:
        LEV_EDIT_KEEP = 0,
        LEV_EDIT_REPLACE = 1,
        LEV_EDIT_INSERT = 2,
        LEV_EDIT_DELETE = 3,
        LEV_EDIT_LAST

    ctypedef struct LevEditOp:
        LevEditType type
        size_t spos
        size_t dpos

    ctypedef struct LevOpCode:
        LevEditType type
        size_t sbeg
        size_t send
        size_t dbeg
        size_t dend

    ctypedef struct LevMatchingBlock:
        size_t spos
        size_t dpos
        size_t len

    cdef void lev_editops_invert(size_t n, LevEditOp *ops) except +
    cdef void lev_opcodes_invert(size_t nb, LevOpCode *bops) except +

    cdef int lev_editops_check_errors(size_t len1, size_t len2, size_t n, const LevEditOp *ops) except +
    cdef int lev_opcodes_check_errors(size_t len1, size_t len2, size_t nb, const LevOpCode *bops) except +

    cdef T* lev_editops_apply[T](size_t len1, const T* string1, size_t len2, const T* string2, size_t n, const LevEditOp *ops, size_t *len) except +
    cdef T* lev_opcodes_apply[T](size_t len1, const T* string1, size_t len2, const T* string2, size_t nb, const LevOpCode *bops, size_t *len) except +

    cdef LevMatchingBlock* lev_editops_matching_blocks(size_t len1, size_t len2, size_t n, const LevEditOp *ops, size_t *nmblocks) except +
    cdef LevMatchingBlock* lev_opcodes_matching_blocks(size_t len1, size_t len2, size_t nb, const LevOpCode *bops, size_t *nmblocks) except +

    cdef LevEditOp* lev_editops_subtract(size_t n, const LevEditOp *ops, size_t ns, const LevEditOp *sub, size_t *nrem) except +

    cdef basic_string[uint32_t] lev_greedy_median(const vector[RF_String]& strings, const vector[double]& weights) except +
    cdef basic_string[uint32_t] lev_median_improve(const RF_String& string, const vector[RF_String]& strings, const vector[double]& weights) except +
    cdef basic_string[uint32_t] lev_quick_median(const vector[RF_String]& strings, const vector[double]& weights) except +
    cdef basic_string[uint32_t] lev_set_median(const vector[RF_String]& strings, const vector[double]& weights) except +

    cdef double lev_set_distance(const vector[RF_String]& strings1, const vector[RF_String]& strings2) except +
    cdef double lev_edit_seq_distance(const vector[RF_String]& strings1, const vector[RF_String]& strings2) except +

    ctypedef struct RF_String:
        pass

    cdef bool is_valid_string(object)
    cdef RF_String convert_string(object)

ctypedef struct OpcodeName:
    PyObject* pystring
    const char *cstring
    size_t len

cdef OpcodeName opcode_names[4]
opcode_names[0] = OpcodeName(<PyObject*>"equal",   "equal",   strlen("equal"))
opcode_names[1] = OpcodeName(<PyObject*>"replace", "replace", strlen("replace"))
opcode_names[2] = OpcodeName(<PyObject*>"insert",  "insert",  strlen("insert"))
opcode_names[3] = OpcodeName(<PyObject*>"delete",  "delete",  strlen("delete"))
cdef size_t N_OPCODE_NAMES = 4

cdef inline RF_String conv_sequence(seq) except *:
    if is_valid_string(seq):
        return convert_string(seq)
    raise TypeError("Expected string or bytes")

cdef size_t get_length_of_anything(o):
    cdef Py_ssize_t length
    if isinstance(o, int):
        length = <Py_ssize_t>o
        if length < 0:
            return <size_t>-1
        return <size_t>length

    if PySequence_Check(o):
        return <size_t>PySequence_Length(o)
    
    return <size_t>-1

cdef LevEditType string_to_edittype(string):
    for i in range(N_OPCODE_NAMES):
        if <PyObject*>string == opcode_names[i].pystring:
           return <LevEditType>i

    if not isinstance(string, str):
        return LEV_EDIT_LAST

    for i in range(N_OPCODE_NAMES):
        if not PyUnicode_CompareWithASCIIString(string, <char*>opcode_names[i].cstring):
            return <LevEditType>i

    return LEV_EDIT_LAST


cdef LevEditOp* extract_editops(list editops) except *:
    cdef size_t n = <size_t>len(editops)
    cdef LevEditOp* ops = <LevEditOp*>safe_malloc(n, sizeof(LevEditOp))

    if not ops:
        raise MemoryError

    for i in range(n):
        editop = editops[i]

        if not isinstance(editop, tuple) or len(<tuple>editop) != 3:
            free(ops)
            return NULL
        
        _type, spos, dpos = <tuple>editop
        if not isinstance(spos, int) or not isinstance(dpos, int):
            free(ops)
            return NULL

        ops[i].spos = <size_t>spos
        ops[i].dpos = <size_t>dpos
        ops[i].type = string_to_edittype(_type)
        if ops[i].type == LEV_EDIT_LAST:
            free(ops)
            return NULL
    
    return ops


cdef LevOpCode* extract_opcodes(list opcodes) except *:
    cdef size_t nb = <size_t>len(opcodes)
    cdef LevOpCode* bops = <LevOpCode*>safe_malloc(nb, sizeof(LevOpCode))

    if not bops:
        raise MemoryError

    for i in range(nb):
        opcode = opcodes[i]

        if not isinstance(opcode, tuple) or len(<tuple>opcode) !=5:
            free(bops)
            return NULL
        
        _type, sbeg, send, dbeg, dend = <tuple>opcode
        if (not isinstance(sbeg, int) or not isinstance(send, int) or
               not isinstance(dbeg, int) or not isinstance(dend, int)):
            free(bops)
            return NULL

        bops[i].sbeg = <size_t>sbeg
        bops[i].send = <size_t>send
        bops[i].dbeg = <size_t>dbeg
        bops[i].dend = <size_t>dend
        bops[i].type = string_to_edittype(_type)
        if bops[i].type == LEV_EDIT_LAST:
            free(bops)
            return NULL
    
    return bops


cdef editops_to_tuple_list(size_t n, LevEditOp *ops):
    cdef list tuple_list = PyList_New(<Py_ssize_t>n)

    for i in range(n):
        result_item = (
            <object>opcode_names[<size_t>ops[i].type].pystring,
            ops[i].spos, ops[i].dpos)
        Py_INCREF(result_item)
        PyList_SET_ITEM(tuple_list, <Py_ssize_t>i, result_item)

    return tuple_list


cdef opcodes_to_tuple_list(size_t nb, LevOpCode *bops):
    cdef list tuple_list = PyList_New(<Py_ssize_t>nb)

    for i in range(nb):
        result_item = (
            <object>opcode_names[<size_t>bops[i].type].pystring,
            bops[i].sbeg, bops[i].send,
            bops[i].dbeg, bops[i].dend)
        Py_INCREF(result_item)
        PyList_SET_ITEM(tuple_list, <Py_ssize_t>i, result_item)

    return tuple_list

cdef matching_blocks_to_tuple_list(size_t len1, size_t len2, size_t nmb, LevMatchingBlock *mblocks):
    cdef list tuple_list = PyList_New(<Py_ssize_t>nmb + 1)

    for i in range(nmb):
        result_item = (mblocks[i].spos, mblocks[i].dpos, mblocks[i].len)
        Py_INCREF(result_item)
        PyList_SET_ITEM(tuple_list, <Py_ssize_t>i, result_item)

    result_item = (len1, len2, 0)
    Py_INCREF(result_item)
    PyList_SET_ITEM(tuple_list, <Py_ssize_t>nmb, result_item)
    return tuple_list

def inverse(edit_operations, *):
    """
    Invert the sense of an edit operation sequence.

    In other words, it returns a list of edit operations transforming the
    second (destination) string to the first (source).  It can be used
    with both editops and opcodes.

    Parameters
    ----------
    edit_operations : list[]
        edit operations to invert

    Returns
    -------
    edit_operations : list[]
        inverted edit operations

    Examples
    --------
    >>> inverse(editops('spam', 'park'))
    [('insert', 0, 0), ('delete', 2, 3), ('replace', 3, 3)]
    >>> editops('park', 'spam')
    [('insert', 0, 0), ('delete', 2, 3), ('replace', 3, 3)]
    """
    cdef size_t n
    cdef LevEditOp* ops
    cdef LevOpCode* bops

    if not isinstance(edit_operations, list):
        raise TypeError("inverse expected a list of edit operations")

    n = <size_t>len(<list>edit_operations)
    if not n:
        return edit_operations

    ops = extract_editops(edit_operations)
    if ops:
        lev_editops_invert(n, ops)
        result = editops_to_tuple_list(n, ops)
        free(ops)
        return result

    bops = extract_opcodes(edit_operations)
    if bops:
       lev_opcodes_invert(n, bops)
       result = opcodes_to_tuple_list(n, bops)
       free(bops)
       return result


    raise TypeError("inverse expected a list of edit operations")


def editops(*args):
    """
    Find sequence of edit operations transforming one string to another.
    
    editops(source_string, destination_string)
    editops(edit_operations, source_length, destination_length)
    
    The result is a list of triples (operation, spos, dpos), where
    operation is one of 'equal', 'replace', 'insert', or 'delete';  spos
    and dpos are position of characters in the first (source) and the
    second (destination) strings.  These are operations on signle
    characters.  In fact the returned list doesn't contain the 'equal',
    but all the related functions accept both lists with and without
    'equal's.
    
    Examples
    --------
    >>> editops('spam', 'park')
    [('delete', 0, 0), ('insert', 3, 2), ('replace', 3, 3)]
    
    The alternate form editops(opcodes, source_string, destination_string)
    can be used for conversion from opcodes (5-tuples) to editops (you can
    pass strings or their lengths, it doesn't matter).
    """
    cdef size_t n, len1, len2
    cdef LevEditOp* ops
    cdef LevOpCode* bops

    # convert: we were called (bops, s1, s2)
    if len(args) == 3:
        arg1, arg2, arg3 = args
        len1 = get_length_of_anything(arg2)
        len2 = get_length_of_anything(arg3)
        if len1 == <size_t>-1 or len2 == <size_t>-1:
            raise ValueError("editops second and third argument must specify sizes")

        return RfEditops(arg1, len1, len2).as_list()

    # find editops: we were called (s1, s2)
    arg1, arg2 = args
    return rf_editops(arg1, arg2).as_list()


def opcodes(*args):
    """
    Find sequence of edit operations transforming one string to another.
    
    opcodes(source_string, destination_string)
    opcodes(edit_operations, source_length, destination_length)
    
    The result is a list of 5-tuples with the same meaning as in
    SequenceMatcher's get_opcodes() output.  But since the algorithms
    differ, the actual sequences from Levenshtein and SequenceMatcher
    may differ too.
    
    Examples
    --------
    >>> for x in opcodes('spam', 'park'):
    ...     print(x)
    ...
    ('delete', 0, 1, 0, 0)
    ('equal', 1, 3, 0, 2)
    ('insert', 3, 3, 2, 3)
    ('replace', 3, 4, 3, 4)
    
    The alternate form opcodes(editops, source_string, destination_string)
    can be used for conversion from editops (triples) to opcodes (you can
    pass strings or their lengths, it doesn't matter).
    """
    cdef size_t n, nb, len1, len2
    cdef LevEditOp* ops
    cdef LevOpCode* bops

    # convert: we were called (ops, s1, s2)
    if len(args) == 3:
        arg1, arg2, arg3 = args
        len1 = get_length_of_anything(arg2)
        len2 = get_length_of_anything(arg3)
        if len1 == <size_t>-1 or len2 == <size_t>-1:
            raise ValueError("opcodes second and third argument must specify sizes")

        return RfOpcodes(arg1, len1, len2).as_list()

    # find editops: we were called (s1, s2)
    arg1, arg2 = args
    return rf_opcodes(arg1, arg2).as_list()


def matching_blocks(edit_operations, source_string, destination_string, *):
    """
    Find identical blocks in two strings.

    Parameters
    ----------
    edit_operations : list[]
        editops or opcodes created for the source and destination string
    source_string : str | int
        source string or the length of the source string
    destination_string : str | int
        destination string or the length of the destination string

    Returns
    -------
    matching_blocks : list[]
        List of triples with the same meaning as in SequenceMatcher's
        get_matching_blocks() output.

    Examples
    --------
    >>> a, b = 'spam', 'park'
    >>> matching_blocks(editops(a, b), a, b)
    [(1, 0, 2), (4, 4, 0)]
    >>> matching_blocks(editops(a, b), len(a), len(b))
    [(1, 0, 2), (4, 4, 0)]
    
    The last zero-length block is not an error, but it's there for
    compatibility with difflib which always emits it.
    
    One can join the matching blocks to get two identical strings:

    >>> a, b = 'dog kennels', 'mattresses'
    >>> mb = matching_blocks(editops(a,b), a, b)
    >>> ''.join([a[x[0]:x[0]+x[2]] for x in mb])
    'ees'
    >>> ''.join([b[x[1]:x[1]+x[2]] for x in mb])
    'ees'
    """
    cdef size_t n, nmb, len1, len2
    cdef LevEditOp* ops
    cdef LevOpCode* bops
    cdef LevMatchingBlock* mblocks

    if not isinstance(edit_operations, list):
        raise TypeError("matching_blocks first argument must be a List of edit operations")

    n = <size_t>len(<list>edit_operations)
    len1 = get_length_of_anything(source_string)
    len2 = get_length_of_anything(destination_string)
    if len1 == <size_t>-1 or len2 == <size_t>-1:
        raise ValueError("matching_blocks second and third argument must specify sizes")


    ops = extract_editops(edit_operations)
    if ops:
        if lev_editops_check_errors(len1, len2, n, ops):
            free(ops)
            raise ValueError("matching_blocks edit operations are invalid or inapplicable")

        mblocks = lev_editops_matching_blocks(len1, len2, n, ops, &nmb)
        free(ops)
        if not mblocks and n:
            raise MemoryError

        result = matching_blocks_to_tuple_list(len1, len2, nmb, mblocks)
        free(mblocks)
        return result

    bops = extract_opcodes(edit_operations)
    if bops:
        if lev_opcodes_check_errors(len1, len2, n, bops):
            free(bops)
            raise ValueError("matching_blocks edit operations are invalid or inapplicable")

        mblocks = lev_opcodes_matching_blocks(len1, len2, n, bops, &nmb)
        free(bops)
        if not mblocks and n:
            raise MemoryError

        result = matching_blocks_to_tuple_list(len1, len2, nmb, mblocks)
        free(mblocks)
        return result

    raise TypeError("matching_blocks expected a list of edit operations")


def subtract_edit(edit_operations, subsequence, *):
    """
    Subtract an edit subsequence from a sequence.
    
    subtract_edit(edit_operations, subsequence)
    
    The result is equivalent to
    editops(apply_edit(subsequence, s1, s2), s2), except that is
    constructed directly from the edit operations.  That is, if you apply
    it to the result of subsequence application, you get the same final
    string as from application complete edit_operations.  It may be not
    identical, though (in amibuous cases, like insertion of a character
    next to the same character).
    
    The subtracted subsequence must be an ordered subset of
    edit_operations.
    
    Note this function does not accept difflib-style opcodes as no one in
    his right mind wants to create subsequences from them.

    Examples
    --------
    >>> e = editops('man', 'scotsman')
    >>> e1 = e[:3]
    >>> bastard = apply_edit(e1, 'man', 'scotsman')
    >>> bastard
    'scoman'
    >>> apply_edit(subtract_edit(e, e1), bastard, 'scotsman')
    'scotsman'
    """
    cdef size_t n, ns, nr
    cdef LevEditOp* ops
    cdef LevEditOp* osub
    cdef LevEditOp* orem

    if not isinstance(edit_operations, list) or not isinstance(subsequence, list):
        raise TypeError("subtract_edit expected two lists of edit operations")

    ns = <size_t>len(<list>subsequence)
    if not ns:
        return edit_operations
    
    n = <size_t>len(<list>edit_operations)
    if not n:
        raise ValueError("subtract_edit subsequence is not a subsequence or is invalid")

    ops = extract_editops(edit_operations)
    if ops:
        osub = extract_editops(subsequence)
        if osub:
            orem = lev_editops_subtract(n, ops, ns, osub, &nr)
            free(ops)
            free(osub)

            if not orem and nr == <size_t>-1:
                raise ValueError("subtract_edit subsequence is not a subsequence or is invalid")

            result = editops_to_tuple_list(nr, orem)
            free(orem)
            return result

        free(ops)

    raise TypeError("subtract_edit expected two lists of edit operations")



def apply_edit(edit_operations, source_string, destination_string, *):
    """
    Apply a sequence of edit operations to a string.
    
    apply_edit(edit_operations, source_string, destination_string)
    
    In the case of editops, the sequence can be arbitrary ordered subset
    of the edit sequence transforming source_string to destination_string.
    
    Examples
    --------
    >>> e = editops('man', 'scotsman')
    >>> apply_edit(e, 'man', 'scotsman')
    'scotsman'
    >>> apply_edit(e[:3], 'man', 'scotsman')
    'scoman'
    
    The other form of edit operations, opcodes, is not very suitable for
    such a tricks, because it has to always span over complete strings,
    subsets can be created by carefully replacing blocks with 'equal'
    blocks, or by enlarging 'equal' block at the expense of other blocks
    and adjusting the other blocks accordingly.

    >>> a, b = 'spam and eggs', 'foo and bar'
    >>> e = opcodes(a, b)
    >>> apply_edit(inverse(e), b, a)
    'spam and eggs'
    >>> e[4] = ('equal', 10, 13, 8, 11)
    >>> e
    [('delete', 0, 1, 0, 0), ('replace', 1, 4, 0, 3), ('equal', 4, 9, 3, 8), ('delete', 9, 10, 8, 8), ('equal', 10, 13, 8, 11)]
    >>> apply_edit(e, a, b)
    'foo and ggs'
    """
    cdef size_t n, len1, len2, len3
    cdef LevEditOp *ops
    cdef LevOpCode *bops

    if not isinstance(edit_operations, list):
        raise TypeError("apply_edit first argument must be a List of edit operations")

    n = <size_t>len(<list>edit_operations)

    if isinstance(source_string, bytes) and isinstance(destination_string, bytes):
        if not n:
            return source_string
        
        len1 = <size_t>len(<bytes>source_string)
        len2 = <size_t>len(<bytes>destination_string)

        string1 = PyBytes_AS_STRING(source_string)
        string2 = PyBytes_AS_STRING(destination_string)

        ops = extract_editops(edit_operations)
        if ops:
            if lev_editops_check_errors(len1, len2, n, ops):
                free(ops)
                raise ValueError("apply_edit edit operations are invalid or inapplicable")

            s = <void*>lev_editops_apply[uint8_t](len1, <const uint8_t*>string1, len2, <const uint8_t*>string2,
                            n, ops, &len3)
            free(ops)
            if not s and len3:
                raise MemoryError
            
            result = PyBytes_FromStringAndSize(<const char*>s, <Py_ssize_t>len3)
            free(s)
            return result

        bops = extract_opcodes(edit_operations)
        if bops:
            if lev_opcodes_check_errors(len1, len2, n, bops):
                free(bops)
                raise ValueError("apply_edit edit operations are invalid or inapplicable")
            
            s = <void*>lev_opcodes_apply[uint8_t](len1, <const uint8_t*>string1, len2, <const uint8_t*>string2,
                            n, bops, &len3)
            free(bops)
            if not s and len3:
                raise MemoryError

            result = PyBytes_FromStringAndSize(<const char*>s, <Py_ssize_t>len3)
            free(s)
            return result
        
        raise TypeError("apply_edit first argument must be a list of edit operations")

    if isinstance(source_string, str) and isinstance(destination_string, str):
        if not n:
            return source_string
        
        len1 = <size_t>len(<str>source_string)
        len2 = <size_t>len(<str>destination_string)

        string1 = PyUnicode_AS_UNICODE(source_string)
        string2 = PyUnicode_AS_UNICODE(destination_string)

        ops = extract_editops(edit_operations)
        if ops:
            if lev_editops_check_errors(len1, len2, n, ops):
                free(ops)
                raise ValueError("apply_edit edit operations are invalid or inapplicable")

            s = <void*>lev_editops_apply[wchar_t](len1, <const wchar_t*>string1, len2, <const wchar_t*>string2,
                            n, ops, &len3)
            free(ops)
            if not s and len3:
                raise MemoryError
            
            result = PyUnicode_FromWideChar(<const wchar_t*>s, <Py_ssize_t>len3)
            free(s)
            return result

        bops = extract_opcodes(edit_operations)
        if bops:
            if lev_opcodes_check_errors(len1, len2, n, bops):
                free(bops)
                raise ValueError("apply_edit edit operations are invalid or inapplicable")
            
            s = <void*>lev_opcodes_apply[wchar_t](len1, <const wchar_t*>string1, len2, <const wchar_t*>string2,
                            n, bops, &len3)
            free(bops)
            if not s and len3:
                raise MemoryError

            result = PyUnicode_FromWideChar(<const wchar_t*>s, <Py_ssize_t>len3)
            free(s)
            return result
        
        raise TypeError("apply_edit first argument must be a list of edit operations")
    
    raise TypeError("apply_edit expected two Strings or two Unicodes")


cdef vector[double] extract_weightlist(wlist, size_t n) except *:
    cdef size_t i
    cdef double weight
    cdef vector[double] weights

    if wlist is None:
        weights.resize(n, 1.0)
    else:
        weights.resize(n)
        for i, w in enumerate(wlist):
            weight = w
            if w < 0:
                raise ValueError(f"weight {weight} is negative")
            weights[i] = w
    return weights

cdef vector[RF_String] extract_stringlist(strings) except *:
    cdef vector[RF_String] strlist

    for string in strings:
        strlist.push_back(move(conv_sequence(string)))
    
    return move(strlist)

def median(strlist, wlist = None, *):
    """
    Find an approximate generalized median string using greedy algorithm.

    You can optionally pass a weight for each string as the second
    argument.  The weights are interpreted as item multiplicities,
    although any non-negative real numbers are accepted.  Use them to
    improve computation speed when strings often appear multiple times
    in the sequence.
    
    Examples
    --------
    
    >>> median(['SpSm', 'mpamm', 'Spam', 'Spa', 'Sua', 'hSam'])
    'Spam'
    >>> fixme = ['Levnhtein', 'Leveshein', 'Leenshten',
                 'Leveshtei', 'Lenshtein', 'Lvenstein',
                 'Levenhtin', 'evenshtei']
    >>> median(fixme)
    'Levenshtein'
    
    Hm.  Even a computer program can spell Levenshtein better than me.
    """
    if wlist is not None and len(strlist) != len(wlist):
        raise ValueError("strlist has a different length than wlist")

    weights = extract_weightlist(wlist, len(strlist))
    strings = extract_stringlist(strlist)
    median = lev_greedy_median(strings, weights)
    return PyUnicode_FromKindAndData(PyUnicode_4BYTE_KIND, median.data(), median.size())

def quickmedian(strlist, wlist = None, *):
    """
    Find a very approximate generalized median string, but fast.

    See median() for argument description.

    This method is somewhere between setmedian() and picking a random
    string from the set; both speedwise and quality-wise.

    Examples
    --------

    >>> fixme = ['Levnhtein', 'Leveshein', 'Leenshten',
                'Leveshtei', 'Lenshtein', 'Lvenstein',
                'Levenhtin', 'evenshtei']
    >>> quickmedian(fixme)
    'Levnshein'
    """
    if wlist is not None and len(strlist) != len(wlist):
        raise ValueError("strlist has a different length than wlist")

    weights = extract_weightlist(wlist, len(strlist))
    strings = extract_stringlist(strlist)
    median = lev_quick_median(strings, weights)
    return PyUnicode_FromKindAndData(PyUnicode_4BYTE_KIND, median.data(), median.size())

def median_improve(string, strlist, wlist = None, *):
    """
    Improve an approximate generalized median string by perturbations.

    The first argument is the estimated generalized median string you
    want to improve, the others are the same as in median(). It returns
    a string with total distance less or equal to that of the given string.

    Note this is much slower than median(). Also note it performs only
    one improvement step, calling median_improve() again on the result
    may improve it further, though this is unlikely to happen unless the
    given string was not very similar to the actual generalized median.

    Examples
    --------

    >>> fixme = ['Levnhtein', 'Leveshein', 'Leenshten',
                 'Leveshtei', 'Lenshtein', 'Lvenstein',
                 'Levenhtin', 'evenshtei']
    >>> median_improve('spam', fixme)
    'enhtein'
    >>> median_improve(median_improve('spam', fixme), fixme)
    'Levenshtein'

    It takes some work to change spam to Levenshtein.
    """
    if wlist is not None and len(strlist) != len(wlist):
        raise ValueError("strlist has a different length than wlist")

    weights = extract_weightlist(wlist, len(strlist))
    query = conv_sequence(string)
    strings = extract_stringlist(strlist)
    median = lev_median_improve(query, strings, weights)
    return PyUnicode_FromKindAndData(PyUnicode_4BYTE_KIND, median.data(), median.size())

def setmedian(strlist, wlist = None, *):
    """
    Find set median of a string set (passed as a sequence).

    See median() for argument description.
    
    The returned string is always one of the strings in the sequence.
    
    Examples
    --------
    
    >>> setmedian(['ehee', 'cceaes', 'chees', 'chreesc',
                   'chees', 'cheesee', 'cseese', 'chetese'])
    'chees'
    
    You haven't asked me about Limburger, sir.
    """

    if wlist is not None and len(strlist) != len(wlist):
        raise ValueError("strlist has a different length than wlist")

    weights = extract_weightlist(wlist, len(strlist))
    strings = extract_stringlist(strlist)
    median = lev_set_median(strings, weights)
    return PyUnicode_FromKindAndData(PyUnicode_4BYTE_KIND, median.data(), median.size())

def setratio(strlist1, strlist2, *):
    """
    Compute similarity ratio of two strings sets (passed as sequences).

    The best match between any strings in the first set and the second
    set (passed as sequences) is attempted.  I.e., the order doesn't
    matter here.
    
    Examples
    --------
    
    >>> setratio(['newspaper', 'litter bin', 'tinny', 'antelope'],
                 ['caribou', 'sausage', 'gorn', 'woody'])
    0.281845...
    
    No, even reordering doesn't help the tinny words to match the
    woody ones.
    """

    strings1 = extract_stringlist(strlist1)
    strings2 = extract_stringlist(strlist2)
    lensum = strings1.size() + strings2.size()

    if lensum == 0:
        return 1.0

    if strings1.empty():
        dist = <double>strings2.size()
    elif strings2.empty():
        dist = <double>strings1.size()
    else:
        dist = lev_set_distance(strings1, strings2)

    return <double>lensum - dist / <double>lensum

def seqratio(strlist1, strlist2, *):
    """
    Compute similarity ratio of two sequences of strings.
    
    This is like ratio(), but for string sequences.  A kind of ratio()
    is used to to measure the cost of item change operation for the
    strings.
    
    Examples
    --------
    
    >>> seqratio(['newspaper', 'litter bin', 'tinny', 'antelope'],
    ...          ['caribou', 'sausage', 'gorn', 'woody'])
    0.21517857142857144
    """

    strings1 = extract_stringlist(strlist1)
    strings2 = extract_stringlist(strlist2)
    lensum = strings1.size() + strings2.size()

    if lensum == 0:
        return 1.0

    if strings1.empty():
        dist = <double>strings2.size()
    elif strings2.empty():
        dist = <double>strings1.size()
    else:
        dist = lev_edit_seq_distance(strings1, strings2)

    return <double>lensum - dist / <double>lensum
