# cython: binding=True
# cython: auto_pickle=False
# cython: language_level=3

"""
The ``lxml.etree`` module implements the extended ElementTree API for XML.
"""

__docformat__ = "restructuredtext en"

__all__ = [
    'AttributeBasedElementClassLookup', 'C14NError', 'C14NWriterTarget', 'CDATA',
    'Comment', 'CommentBase', 'CustomElementClassLookup', 'DEBUG',
    'DTD', 'DTDError', 'DTDParseError', 'DTDValidateError',
    'DocumentInvalid', 'ETCompatXMLParser', 'ETXPath', 'Element',
    'ElementBase', 'ElementClassLookup', 'ElementDefaultClassLookup',
    'ElementNamespaceClassLookup', 'ElementTree', 'Entity', 'EntityBase',
    'Error', 'ErrorDomains', 'ErrorLevels', 'ErrorTypes', 'Extension',
    'FallbackElementClassLookup', 'FunctionNamespace', 'HTML', 'HTMLParser',
    'ICONV_COMPILED_VERSION',
    'LIBXML_COMPILED_VERSION', 'LIBXML_VERSION',
    'LIBXML_FEATURES',
    'LIBXSLT_COMPILED_VERSION', 'LIBXSLT_VERSION',
    'LXML_VERSION',
    'LxmlError', 'LxmlRegistryError', 'LxmlSyntaxError',
    'NamespaceRegistryError', 'PI', 'PIBase', 'ParseError',
    'ParserBasedElementClassLookup', 'ParserError', 'ProcessingInstruction',
    'PyErrorLog', 'PythonElementClassLookup', 'QName', 'RelaxNG',
    'RelaxNGError', 'RelaxNGErrorTypes', 'RelaxNGParseError',
    'RelaxNGValidateError', 'Resolver', 'Schematron', 'SchematronError',
    'SchematronParseError', 'SchematronValidateError', 'SerialisationError',
    'SubElement', 'TreeBuilder', 'XInclude', 'XIncludeError', 'XML',
    'XMLDTDID', 'XMLID', 'XMLParser', 'XMLSchema', 'XMLSchemaError',
    'XMLSchemaParseError', 'XMLSchemaValidateError', 'XMLSyntaxError',
    'XMLTreeBuilder', 'XPath', 'XPathDocumentEvaluator', 'XPathError',
    'XPathEvalError', 'XPathEvaluator', 'XPathFunctionError', 'XPathResultError',
    'XPathSyntaxError', 'XSLT', 'XSLTAccessControl', 'XSLTApplyError',
    'XSLTError', 'XSLTExtension', 'XSLTExtensionError', 'XSLTParseError',
    'XSLTSaveError', 'canonicalize',
    'cleanup_namespaces', 'clear_error_log', 'dump',
    'fromstring', 'fromstringlist', 'get_default_parser', 'iselement',
    'iterparse', 'iterwalk', 'parse', 'parseid', 'register_namespace',
    'set_default_parser', 'set_element_class_lookup', 'strip_attributes',
    'strip_elements', 'strip_tags', 'tostring', 'tostringlist', 'tounicode',
    'use_global_python_log'
    ]

cimport cython

from lxml cimport python
from lxml.includes cimport tree, config
from lxml.includes.tree cimport xmlDoc, xmlNode, xmlAttr, xmlNs, _isElement, _getNs
from lxml.includes.tree cimport const_xmlChar, xmlChar, _xcstr
from lxml.python cimport _cstr, _isString
from lxml.includes cimport xpath
from lxml.includes cimport c14n

# Cython's standard declarations
cimport cpython.mem
cimport cpython.ref
from libc cimport limits, stdio, stdlib
from libc cimport string as cstring_h   # not to be confused with stdlib 'string'
from libc.string cimport const_char

cdef object os_path_abspath
from os.path import abspath as os_path_abspath

cdef object BytesIO, StringIO
from io import BytesIO, StringIO

cdef object OrderedDict
from collections import OrderedDict

cdef object _elementpath
from lxml import _elementpath

cdef object sys
import sys

cdef object re
import re

cdef object partial
from functools import partial

cdef object islice
from itertools import islice

cdef object ITER_EMPTY = iter(())

cdef object MutableMapping
from collections.abc import MutableMapping

class _ImmutableMapping(MutableMapping):
    def __getitem__(self, key):
        raise KeyError, key

    def __setitem__(self, key, value):
        raise KeyError, key

    def __delitem__(self, key):
        raise KeyError, key

    def __contains__(self, key):
        return False

    def __len__(self):
        return 0

    def __iter__(self):
        return ITER_EMPTY
    iterkeys = itervalues = iteritems = __iter__

cdef object IMMUTABLE_EMPTY_MAPPING = _ImmutableMapping()
del _ImmutableMapping


# the rules
# ---------
# any libxml C argument/variable is prefixed with c_
# any non-public function/class is prefixed with an underscore
# instance creation is always through factories

# what to do with libxml2/libxslt error messages?
# 0 : drop
# 1 : use log
DEF __DEBUG = 1

# maximum number of lines in the libxml2/xslt log if __DEBUG == 1
DEF __MAX_LOG_SIZE = 100

# make the compiled-in debug state publicly available
DEBUG = __DEBUG

# A struct to store a cached qualified tag name+href pair.
# While we can borrow the c_name from the document dict,
# PyPy requires us to store a Python reference for the
# namespace in order to keep the byte buffer alive.
cdef struct qname:
    const_xmlChar* c_name
    python.PyObject* href

# initialize parser (and threading)
xmlparser.xmlInitParser()

# global per-thread setup
tree.xmlThrDefIndentTreeOutput(1)
tree.xmlThrDefLineNumbersDefaultValue(1)

_initThreadLogging()

# filename encoding
cdef bytes _FILENAME_ENCODING = (sys.getfilesystemencoding() or sys.getdefaultencoding() or 'ascii').encode("UTF-8")
cdef char* _C_FILENAME_ENCODING = _cstr(_FILENAME_ENCODING)

# set up some default namespace prefixes
cdef dict _DEFAULT_NAMESPACE_PREFIXES = {
    b"http://www.w3.org/XML/1998/namespace": b'xml',
    b"http://www.w3.org/1999/xhtml": b"html",
    b"http://www.w3.org/1999/XSL/Transform": b"xsl",
    b"http://www.w3.org/1999/02/22-rdf-syntax-ns#": b"rdf",
    b"http://schemas.xmlsoap.org/wsdl/": b"wsdl",
    # xml schema
    b"http://www.w3.org/2001/XMLSchema": b"xs",
    b"http://www.w3.org/2001/XMLSchema-instance": b"xsi",
    # dublin core
    b"http://purl.org/dc/elements/1.1/": b"dc",
    # objectify
    b"http://codespeak.net/lxml/objectify/pytype" : b"py",
}

# To avoid runtime encoding overhead, we keep a Unicode copy
# of the uri-prefix mapping as (str, str) items view.
cdef object _DEFAULT_NAMESPACE_PREFIXES_ITEMS = []

cdef _update_default_namespace_prefixes_items():
    cdef bytes ns, prefix
    global _DEFAULT_NAMESPACE_PREFIXES_ITEMS
    _DEFAULT_NAMESPACE_PREFIXES_ITEMS = {
        ns.decode('utf-8') : prefix.decode('utf-8')
        for ns, prefix in _DEFAULT_NAMESPACE_PREFIXES.items()
    }.items()

_update_default_namespace_prefixes_items()

cdef object _check_internal_prefix = re.compile(br"ns\d+$").match

def register_namespace(prefix, uri):
    """Registers a namespace prefix that newly created Elements in that
    namespace will use.  The registry is global, and any existing
    mapping for either the given prefix or the namespace URI will be
    removed.
    """
    prefix_utf, uri_utf = _utf8(prefix), _utf8(uri)
    if _check_internal_prefix(prefix_utf):
        raise ValueError("Prefix format reserved for internal use")
    _tagValidOrRaise(prefix_utf)
    _uriValidOrRaise(uri_utf)
    if (uri_utf == b"http://www.w3.org/XML/1998/namespace" and prefix_utf != b'xml'
            or prefix_utf == b'xml' and uri_utf != b"http://www.w3.org/XML/1998/namespace"):
        raise ValueError("Cannot change the 'xml' prefix of the XML namespace")
    for k, v in list(_DEFAULT_NAMESPACE_PREFIXES.items()):
        if k == uri_utf or v == prefix_utf:
            del _DEFAULT_NAMESPACE_PREFIXES[k]
    _DEFAULT_NAMESPACE_PREFIXES[uri_utf] = prefix_utf
    _update_default_namespace_prefixes_items()


# Error superclass for ElementTree compatibility
cdef class Error(Exception):
    pass

# module level superclass for all exceptions
cdef class LxmlError(Error):
    """Main exception base class for lxml.  All other exceptions inherit from
    this one.
    """
    def __init__(self, message, error_log=None):
        super(_Error, self).__init__(message)
        if error_log is None:
            self.error_log = __copyGlobalErrorLog()
        else:
            self.error_log = error_log.copy()

cdef object _Error = Error


# superclass for all syntax errors
class LxmlSyntaxError(LxmlError, SyntaxError):
    """Base class for all syntax errors.
    """

cdef class C14NError(LxmlError):
    """Error during C14N serialisation.
    """

# version information
cdef tuple __unpackDottedVersion(version):
    version_list = []
    l = (version.decode("ascii").replace('-', '.').split('.') + [0]*4)[:4]
    for item in l:
        try:
            item = int(item)
        except ValueError:
            if item.startswith('dev'):
                count = item[3:]
                item = -300
            elif item.startswith('alpha'):
                count = item[5:]
                item = -200
            elif item.startswith('beta'):
                count = item[4:]
                item = -100
            else:
                count = 0
            if count:
                item += int(count)
        version_list.append(item)
    return tuple(version_list)

cdef tuple __unpackIntVersion(int c_version, int base=100):
    return (
        ((c_version // (base*base)) % base),
        ((c_version // base)        % base),
        (c_version                  % base)
        )

cdef int _LIBXML_VERSION_INT
try:
    _LIBXML_VERSION_INT = int(
        re.match('[0-9]+', (<unsigned char*>tree.xmlParserVersion).decode("ascii")).group(0))
except Exception:
    print("Unknown libxml2 version: " + (<unsigned char*>tree.xmlParserVersion).decode("latin1"))
    _LIBXML_VERSION_INT = 0

LIBXML_VERSION = __unpackIntVersion(_LIBXML_VERSION_INT)
LIBXML_COMPILED_VERSION = __unpackIntVersion(tree.LIBXML_VERSION)
LXML_VERSION = __unpackDottedVersion(tree.LXML_VERSION_STRING)

__version__ = tree.LXML_VERSION_STRING.decode("ascii")

cdef extern from *:
    """
    #ifdef ZLIB_VERNUM
      #define __lxml_zlib_version (ZLIB_VERNUM >> 4)
    #else
      #define __lxml_zlib_version 0
    #endif
    #ifdef _LIBICONV_VERSION
      #define __lxml_iconv_version (_LIBICONV_VERSION << 8)
    #else
      #define __lxml_iconv_version 0
    #endif
    """
    # zlib isn't included automatically by libxml2's headers
    #long ZLIB_HEX_VERSION "__lxml_zlib_version"
    long LIBICONV_HEX_VERSION "__lxml_iconv_version"

#ZLIB_COMPILED_VERSION = __unpackIntVersion(ZLIB_HEX_VERSION, base=0x10)
ICONV_COMPILED_VERSION = __unpackIntVersion(LIBICONV_HEX_VERSION, base=0x100)[:2]


cdef extern from "libxml/xmlversion.h":
    """
    static const char* const _lxml_lib_features[] = {
#ifdef LIBXML_HTML_ENABLED
        "html",
#endif
#ifdef LIBXML_FTP_ENABLED
        "ftp",
#endif
#ifdef LIBXML_HTTP_ENABLED
        "http",
#endif
#ifdef LIBXML_CATALOG_ENABLED
        "catalog",
#endif
#ifdef LIBXML_XPATH_ENABLED
        "xpath",
#endif
#ifdef LIBXML_ICONV_ENABLED
        "iconv",
#endif
#ifdef LIBXML_ICU_ENABLED
        "icu",
#endif
#ifdef LIBXML_REGEXP_ENABLED
        "regexp",
#endif
#ifdef LIBXML_SCHEMAS_ENABLED
        "xmlschema",
#endif
#ifdef LIBXML_SCHEMATRON_ENABLED
        "schematron",
#endif
#ifdef LIBXML_ZLIB_ENABLED
        "zlib",
#endif
#ifdef LIBXML_LZMA_ENABLED
        "lzma",
#endif
        0
    };
    """
    const char* const* _LXML_LIB_FEATURES "_lxml_lib_features"


cdef set _copy_lib_features():
    features = set()
    feature = _LXML_LIB_FEATURES
    while feature[0]:
        features.add(feature[0].decode('ASCII'))
        feature += 1
    return features

LIBXML_COMPILED_FEATURES = _copy_lib_features()
LIBXML_FEATURES = {
    feature_name for feature_id, feature_name in [
        #XML_WITH_THREAD = 1
        #XML_WITH_TREE = 2
        #XML_WITH_OUTPUT = 3
        #XML_WITH_PUSH = 4
        #XML_WITH_READER = 5
        #XML_WITH_PATTERN = 6
        #XML_WITH_WRITER = 7
        #XML_WITH_SAX1 = 8
        (xmlparser.XML_WITH_FTP, "ftp"),  # XML_WITH_FTP = 9
        (xmlparser.XML_WITH_HTTP, "http"),  # XML_WITH_HTTP = 10
        #XML_WITH_VALID = 11
        (xmlparser.XML_WITH_HTML, "html"),  # XML_WITH_HTML = 12
        #XML_WITH_LEGACY = 13
        #XML_WITH_C14N = 14
        (xmlparser.XML_WITH_CATALOG, "catalog"),  # XML_WITH_CATALOG = 15
        (xmlparser.XML_WITH_XPATH, "xpath"),  # XML_WITH_XPATH = 16
        #XML_WITH_XPTR = 17
        #XML_WITH_XINCLUDE = 18
        (xmlparser.XML_WITH_ICONV, "iconv"),  # XML_WITH_ICONV = 19
        #XML_WITH_ISO8859X = 20
        #XML_WITH_UNICODE = 21
        (xmlparser.XML_WITH_REGEXP, "regexp"),  # XML_WITH_REGEXP = 22
        #XML_WITH_AUTOMATA = 23
        #XML_WITH_EXPR = 24
        (xmlparser.XML_WITH_SCHEMAS, "xmlschema"),  # XML_WITH_SCHEMAS = 25
        (xmlparser.XML_WITH_SCHEMATRON, "schematron"),  # XML_WITH_SCHEMATRON = 26
        #XML_WITH_MODULES = 27
        #XML_WITH_DEBUG = 28
        #XML_WITH_DEBUG_MEM = 29
        #XML_WITH_DEBUG_RUN = 30  # unused
        (xmlparser.XML_WITH_ZLIB, "zlib"),  # XML_WITH_ZLIB = 31
        (xmlparser.XML_WITH_ICU, "icu"),  # XML_WITH_ICU = 32
        (xmlparser.XML_WITH_LZMA, "lzma"),  # XML_WITH_LZMA = 33
    ] if xmlparser.xmlHasFeature(feature_id)
}

cdef bint HAS_ZLIB_COMPRESSION = xmlparser.xmlHasFeature(xmlparser.XML_WITH_ZLIB)


# class for temporary storage of Python references,
# used e.g. for XPath results
@cython.final
@cython.internal
cdef class _TempStore:
    cdef list _storage
    def __init__(self):
        self._storage = []

    cdef int add(self, obj) except -1:
        self._storage.append(obj)
        return 0

    cdef int clear(self) except -1:
        del self._storage[:]
        return 0


# class for temporarily storing exceptions raised in extensions
@cython.internal
cdef class _ExceptionContext:
    cdef object _exc_info

    cdef int clear(self) except -1:
        self._exc_info = None
        return 0

    @cython.final
    cdef void _store_raised(self) noexcept:
        try:
            self._exc_info = sys.exc_info()
        except BaseException as e:
            self._store_exception(e)
        finally:
            return  # and swallow any further exceptions

    @cython.final
    cdef int _store_exception(self, exception) except -1:
        self._exc_info = (exception, None, None)
        return 0

    @cython.final
    cdef bint _has_raised(self) except -1:
        return self._exc_info is not None

    @cython.final
    cdef int _raise_if_stored(self) except -1:
        if self._exc_info is None:
            return 0
        type, value, traceback = self._exc_info
        self._exc_info = None
        if value is None and traceback is None:
            raise type
        else:
            raise type, value, traceback


# type of a function that steps from node to node
ctypedef public xmlNode* (*_node_to_node_function)(xmlNode*)


################################################################################
# Include submodules

include "proxy.pxi"        # Proxy handling (element backpointers/memory/etc.)
include "apihelpers.pxi"   # Private helper functions
include "xmlerror.pxi"     # Error and log handling


################################################################################
# Public Python API

@cython.final
@cython.freelist(8)
cdef public class _Document [ type LxmlDocumentType, object LxmlDocument ]:
    """Internal base class to reference a libxml document.

    When instances of this class are garbage collected, the libxml
    document is cleaned up.
    """
    cdef int _ns_counter
    cdef bytes _prefix_tail
    cdef xmlDoc* _c_doc
    cdef _BaseParser _parser

    def __dealloc__(self):
        # if there are no more references to the document, it is safe
        # to clean the whole thing up, as all nodes have a reference to
        # the document
        tree.xmlFreeDoc(self._c_doc)

    @cython.final
    cdef getroot(self):
        # return an element proxy for the document root
        cdef xmlNode* c_node
        c_node = tree.xmlDocGetRootElement(self._c_doc)
        if c_node is NULL:
            return None
        return _elementFactory(self, c_node)

    @cython.final
    cdef bint hasdoctype(self) noexcept:
        # DOCTYPE gets parsed into internal subset (xmlDTD*)
        return self._c_doc is not NULL and self._c_doc.intSubset is not NULL

    @cython.final
    cdef getdoctype(self):
        # get doctype info: root tag, public/system ID (or None if not known)
        cdef tree.xmlDtd* c_dtd
        cdef xmlNode* c_root_node
        public_id = None
        sys_url   = None
        c_dtd = self._c_doc.intSubset
        if c_dtd is not NULL:
            if c_dtd.ExternalID is not NULL:
                public_id = funicode(c_dtd.ExternalID)
            if c_dtd.SystemID is not NULL:
                sys_url = funicode(c_dtd.SystemID)
        c_dtd = self._c_doc.extSubset
        if c_dtd is not NULL:
            if not public_id and c_dtd.ExternalID is not NULL:
                public_id = funicode(c_dtd.ExternalID)
            if not sys_url and c_dtd.SystemID is not NULL:
                sys_url = funicode(c_dtd.SystemID)
        c_root_node = tree.xmlDocGetRootElement(self._c_doc)
        if c_root_node is NULL:
            root_name = None
        else:
            root_name = funicode(c_root_node.name)
        return root_name, public_id, sys_url

    @cython.final
    cdef getxmlinfo(self):
        # return XML version and encoding (or None if not known)
        cdef xmlDoc* c_doc = self._c_doc
        if c_doc.version is NULL:
            version = None
        else:
            version = funicode(c_doc.version)
        if c_doc.encoding is NULL:
            encoding = None
        else:
            encoding = funicode(c_doc.encoding)
        return version, encoding

    @cython.final
    cdef isstandalone(self):
        # returns True for "standalone=true",
        # False for "standalone=false", None if not provided
        if self._c_doc.standalone == -1:
            return None
        else:
            return <bint>(self._c_doc.standalone == 1)

    @cython.final
    cdef bytes buildNewPrefix(self):
        # get a new unique prefix ("nsX") for this document
        cdef bytes ns
        if self._ns_counter < len(_PREFIX_CACHE):
            ns = _PREFIX_CACHE[self._ns_counter]
        else:
            ns = python.PyBytes_FromFormat("ns%d", self._ns_counter)
        if self._prefix_tail is not None:
            ns += self._prefix_tail
        self._ns_counter += 1
        if self._ns_counter < 0:
            # overflow!
            self._ns_counter = 0
            if self._prefix_tail is None:
                self._prefix_tail = b"A"
            else:
                self._prefix_tail += b"A"
        return ns

    @cython.final
    cdef xmlNs* _findOrBuildNodeNs(self, xmlNode* c_node,
                                   const_xmlChar* c_href, const_xmlChar* c_prefix,
                                   bint is_attribute) except NULL:
        """Get or create namespace structure for a node.  Reuses the prefix if
        possible.
        """
        cdef xmlNs* c_ns
        cdef xmlNs* c_doc_ns
        cdef python.PyObject* dict_result
        if c_node.type != tree.XML_ELEMENT_NODE:
            assert c_node.type == tree.XML_ELEMENT_NODE, \
                "invalid node type %d, expected %d" % (
                c_node.type, tree.XML_ELEMENT_NODE)
        # look for existing ns declaration
        c_ns = _searchNsByHref(c_node, c_href, is_attribute)
        if c_ns is not NULL:
            if is_attribute and c_ns.prefix is NULL:
                # do not put namespaced attributes into the default
                # namespace as this would break serialisation
                pass
            else:
                return c_ns

        # none found => determine a suitable new prefix
        if c_prefix is NULL:
            dict_result = python.PyDict_GetItem(
                _DEFAULT_NAMESPACE_PREFIXES, <unsigned char*>c_href)
            if dict_result is not NULL:
                prefix = <object>dict_result
            else:
                prefix = self.buildNewPrefix()
            c_prefix = _xcstr(prefix)

        # make sure the prefix is not in use already
        while tree.xmlSearchNs(self._c_doc, c_node, c_prefix) is not NULL:
            prefix = self.buildNewPrefix()
            c_prefix = _xcstr(prefix)

        # declare the namespace and return it
        c_ns = tree.xmlNewNs(c_node, c_href, c_prefix)
        if c_ns is NULL:
            raise MemoryError()
        return c_ns

    @cython.final
    cdef int _setNodeNs(self, xmlNode* c_node, const_xmlChar* c_href) except -1:
        "Lookup namespace structure and set it for the node."
        c_ns = self._findOrBuildNodeNs(c_node, c_href, NULL, 0)
        tree.xmlSetNs(c_node, c_ns)


cdef tuple __initPrefixCache():
    cdef int i
    return tuple([ python.PyBytes_FromFormat("ns%d", i)
                   for i in range(26) ])

cdef tuple _PREFIX_CACHE = __initPrefixCache()


cdef _Document _documentFactory(xmlDoc* c_doc, _BaseParser parser):
    cdef _Document result
    result = _Document.__new__(_Document)
    result._c_doc = c_doc
    result._ns_counter = 0
    result._prefix_tail = None
    if parser is None:
        parser = __GLOBAL_PARSER_CONTEXT.getDefaultParser()
    result._parser = parser
    return result


cdef object _find_invalid_public_id_characters = re.compile(
    ur"[^\x20\x0D\x0Aa-zA-Z0-9'()+,./:=?;!*#@$_%-]+").search


cdef class DocInfo:
    "Document information provided by parser and DTD."
    cdef _Document _doc
    def __cinit__(self, tree):
        "Create a DocInfo object for an ElementTree object or root Element."
        self._doc = _documentOrRaise(tree)
        root_name, public_id, system_url = self._doc.getdoctype()
        if not root_name and (public_id or system_url):
            raise ValueError, "Could not find root node"

    @property
    def root_name(self):
        """Returns the name of the root node as defined by the DOCTYPE."""
        root_name, public_id, system_url = self._doc.getdoctype()
        return root_name

    @cython.final
    cdef tree.xmlDtd* _get_c_dtd(self) noexcept:
        """"Return the DTD. Create it if it does not yet exist."""
        cdef xmlDoc* c_doc = self._doc._c_doc
        cdef xmlNode* c_root_node
        cdef const_xmlChar* c_name

        if c_doc.intSubset:
            return c_doc.intSubset

        c_root_node = tree.xmlDocGetRootElement(c_doc)
        c_name = c_root_node.name if c_root_node else NULL
        return  tree.xmlCreateIntSubset(c_doc, c_name, NULL, NULL)

    def clear(self):
        """Removes DOCTYPE and internal subset from the document."""
        cdef xmlDoc* c_doc = self._doc._c_doc
        cdef tree.xmlNode* c_dtd = <xmlNode*>c_doc.intSubset
        if c_dtd is NULL:
            return
        tree.xmlUnlinkNode(c_dtd)
        tree.xmlFreeNode(c_dtd)

    property public_id:
        """Public ID of the DOCTYPE.

        Mutable.  May be set to a valid string or None.  If a DTD does not
        exist, setting this variable (even to None) will create one.
        """
        def __get__(self):
            root_name, public_id, system_url = self._doc.getdoctype()
            return public_id

        def __set__(self, value):
            cdef xmlChar* c_value = NULL
            if value is not None:
                match = _find_invalid_public_id_characters(value)
                if match:
                    raise ValueError, f'Invalid character(s) {match.group(0)!r} in public_id.'
                value = _utf8(value)
                c_value = tree.xmlStrdup(_xcstr(value))
                if not c_value:
                    raise MemoryError()

            c_dtd = self._get_c_dtd()
            if not c_dtd:
                tree.xmlFree(c_value)
                raise MemoryError()
            if c_dtd.ExternalID:
                tree.xmlFree(<void*>c_dtd.ExternalID)
            c_dtd.ExternalID = c_value

    property system_url:
        """System ID of the DOCTYPE.

        Mutable.  May be set to a valid string or None.  If a DTD does not
        exist, setting this variable (even to None) will create one.
        """
        def __get__(self):
            root_name, public_id, system_url = self._doc.getdoctype()
            return system_url

        def __set__(self, value):
            cdef xmlChar* c_value = NULL
            if value is not None:
                bvalue = _utf8(value)
                # sys_url may be any valid unicode string that can be
                # enclosed in single quotes or quotes.
                if b"'" in bvalue and b'"' in bvalue:
                    raise ValueError(
                        'System URL may not contain both single (\') and double quotes (").')
                c_value = tree.xmlStrdup(_xcstr(bvalue))
                if not c_value:
                    raise MemoryError()

            c_dtd = self._get_c_dtd()
            if not c_dtd:
                tree.xmlFree(c_value)
                raise MemoryError()
            if c_dtd.SystemID:
                tree.xmlFree(<void*>c_dtd.SystemID)
            c_dtd.SystemID = c_value

    @property
    def xml_version(self):
        """Returns the XML version as declared by the document."""
        xml_version, encoding = self._doc.getxmlinfo()
        return xml_version

    @property
    def encoding(self):
        """Returns the encoding name as declared by the document."""
        xml_version, encoding = self._doc.getxmlinfo()
        return encoding

    @property
    def standalone(self):
        """Returns the standalone flag as declared by the document.  The possible
        values are True (``standalone='yes'``), False
        (``standalone='no'`` or flag not provided in the declaration),
        and None (unknown or no declaration found).  Note that a
        normal truth test on this value will always tell if the
        ``standalone`` flag was set to ``'yes'`` or not.
        """
        return self._doc.isstandalone()

    property URL:
        "The source URL of the document (or None if unknown)."
        def __get__(self):
            if self._doc._c_doc.URL is NULL:
                return None
            return _decodeFilename(self._doc._c_doc.URL)
        def __set__(self, url):
            url = _encodeFilename(url)
            c_oldurl = self._doc._c_doc.URL
            if url is None:
                self._doc._c_doc.URL = NULL
            else:
                self._doc._c_doc.URL = tree.xmlStrdup(_xcstr(url))
            if c_oldurl is not NULL:
                tree.xmlFree(<void*>c_oldurl)

    @property
    def doctype(self):
        """Returns a DOCTYPE declaration string for the document."""
        root_name, public_id, system_url = self._doc.getdoctype()
        if system_url:
            # If '"' in system_url, we must escape it with single
            # quotes, otherwise escape with double quotes. If url
            # contains both a single quote and a double quote, XML
            # standard is being violated.
            if '"' in system_url:
                quoted_system_url = f"'{system_url}'"
            else:
                quoted_system_url = f'"{system_url}"'
        if public_id:
            if system_url:
                return f'<!DOCTYPE {root_name} PUBLIC "{public_id}" {quoted_system_url}>'
            else:
                return f'<!DOCTYPE {root_name} PUBLIC "{public_id}">'
        elif system_url:
            return f'<!DOCTYPE {root_name} SYSTEM {quoted_system_url}>'
        elif self._doc.hasdoctype():
            return f'<!DOCTYPE {root_name}>'
        else:
            return ''

    @property
    def internalDTD(self):
        """Returns a DTD validator based on the internal subset of the document."""
        return _dtdFactory(self._doc._c_doc.intSubset)

    @property
    def externalDTD(self):
        """Returns a DTD validator based on the external subset of the document."""
        return _dtdFactory(self._doc._c_doc.extSubset)


@cython.no_gc_clear
cdef public class _Element [ type LxmlElementType, object LxmlElement ]:
    """Element class.

    References a document object and a libxml node.

    By pointing to a Document instance, a reference is kept to
    _Document as long as there is some pointer to a node in it.
    """
    cdef _Document _doc
    cdef xmlNode* _c_node
    cdef object _tag

    def _init(self):
        """_init(self)

        Called after object initialisation.  Custom subclasses may override
        this if they recursively call _init() in the superclasses.
        """

    @cython.linetrace(False)
    @cython.profile(False)
    def __dealloc__(self):
        #print("trying to free node:", <int>self._c_node)
        #displayNode(self._c_node, 0)
        if self._c_node is not NULL:
            _unregisterProxy(self)
            attemptDeallocation(self._c_node)

    # MANIPULATORS

    def __setitem__(self, x, value):
        """__setitem__(self, x, value)

        Replaces the given subelement index or slice.
        """
        cdef xmlNode* c_node = NULL
        cdef xmlNode* c_next
        cdef xmlDoc* c_source_doc
        cdef _Element element
        cdef bint left_to_right
        cdef Py_ssize_t slicelength = 0, step = 0
        _assertValidNode(self)
        if value is None:
            raise ValueError, "cannot assign None"
        if isinstance(x, slice):
            # slice assignment
            _findChildSlice(<slice>x, self._c_node, &c_node, &step, &slicelength)
            if step > 0:
                left_to_right = 1
            else:
                left_to_right = 0
                step = -step if step != python.PY_SSIZE_T_MIN else python.PY_SSIZE_T_MAX
            _replaceSlice(self, c_node, slicelength, step, left_to_right, value)
            return
        else:
            # otherwise: normal item assignment
            element = value
            _assertValidNode(element)
            c_node = _findChild(self._c_node, x)
            if c_node is NULL:
                raise IndexError, "list index out of range"
            c_source_doc = element._c_node.doc
            c_next = element._c_node.next
            _removeText(c_node.next)
            tree.xmlReplaceNode(c_node, element._c_node)
            _moveTail(c_next, element._c_node)
            moveNodeToDocument(self._doc, c_source_doc, element._c_node)
            if not attemptDeallocation(c_node):
                moveNodeToDocument(self._doc, c_node.doc, c_node)

    def __delitem__(self, x):
        """__delitem__(self, x)

        Deletes the given subelement or a slice.
        """
        cdef xmlNode* c_node = NULL
        cdef xmlNode* c_next
        cdef Py_ssize_t step = 0, slicelength = 0
        _assertValidNode(self)
        if isinstance(x, slice):
            # slice deletion
            if _isFullSlice(<slice>x):
                c_node = self._c_node.children
                if c_node is not NULL:
                    if not _isElement(c_node):
                        c_node = _nextElement(c_node)
                    while c_node is not NULL:
                        c_next = _nextElement(c_node)
                        _removeNode(self._doc, c_node)
                        c_node = c_next
            else:
                _findChildSlice(<slice>x, self._c_node, &c_node, &step, &slicelength)
                _deleteSlice(self._doc, c_node, slicelength, step)
        else:
            # item deletion
            c_node = _findChild(self._c_node, x)
            if c_node is NULL:
                raise IndexError, f"index out of range: {x}"
            _removeNode(self._doc, c_node)

    def __deepcopy__(self, memo):
        "__deepcopy__(self, memo)"
        return self.__copy__()

    def __copy__(self):
        "__copy__(self)"
        cdef xmlDoc* c_doc
        cdef xmlNode* c_node
        cdef _Document new_doc
        _assertValidNode(self)
        c_doc = _copyDocRoot(self._doc._c_doc, self._c_node) # recursive
        new_doc = _documentFactory(c_doc, self._doc._parser)
        root = new_doc.getroot()
        if root is not None:
            return root
        # Comment/PI
        c_node = c_doc.children
        while c_nodey‚t.:å^LÇ«“ûitZ8ß‘Ãd‹Z8ß’Âob#NË§»Ñ™çTPúàAL…©õH>³…ªıM¬,èépv"6Í·®°ç¡QÄå™\TËû»˜WPğá!DÅ˜ŸR@ïcI¶e´]¹Í—¯pâ#NÈ§±Ñ¥äÜZÊß½ÁŒ†*ÿt8.bçMS¬ëéyv5y¾…w1G¦ÕbıL¨#òÉ/´á¸E’ŸmCm‹o;a›FY—×sò(.òä,Zêİ}Î¤*ÚÿÜ È° 'ÂÑä%[ÜÚÊŞ¾Æ‡—qj&~Õÿx)böL5«¿ùt9Q”æyWóx*ılh%rß.ÃçŠR>ï…bMI­·í±m¤lÙj×~ó+ú\ÉIµ´½»™/Uàş@€}$zØÑFæ•U|ı0"¢ÌÏ« øÀhs*nüd	X7Ó³é¨tò8-’îmgoS`ëA{†Y|Ö
õ<>‹„:ZLßªÃÿ‰4¸!Ç`“Biv#6Ë·º±Ÿ§AÑ…æUJı½Œ.(æğT"úÍ¬@èq%ŞvÄ7™³V¨÷ğ1#¤ÈØ²Ò®ïåa_DÁ™‡Tû`A]„Ï¡XÆÓ•ë|z
=Kº%İFÍ—¯pá!GÅ’ŸnCg‹S8é‘vf7W³ñ«$øØÑbçNQ¦äÕZüÜ	È4³º©Ÿ÷A1„¦ÕSüè	r6,¶èµs¾)†õ={%^ŞÆÅ—œsK)»õš?^€Ä›Z8Ü’Èo³a«Dû˜QYä×ZğÜ!ÊÄ¿šƒ_Á3†ªı{%PÜàÉBµ¾'†Ñåu^<Å‹;G™’Woóc+Hù°¢|Ì©8ö4c»I›·[°Ù¢ÕÎı¤Ø+Òøìinwe3_¨Âó* şÀ‚l(jñ|'
Ó>ê…|D:›[MÙ¯ÔàùB~$ÙÖvô49»–›wZ1ß§ÀĞ‚âO-¢ìÌkªxı`"BÍ¯ áÁF…–wB2­ íÁn‡fWhòp-"ïÍb¯Ná§DĞšá]EÍŸ¯@áƒF”1{¥ßRÂïb,Né¥wŞ1Ç¤ÚbßNÃ§‹Ò9ï”czJ½O¡,Åë{F•W~ò,éHu²=­Œî)g÷R0î¡dÇ[ØbÓNë¥{ŞÅTœúH±C¥‰Ş5Ç¼‘Šf?Wƒò,8ë{bMY®Ôåù\Ê{¼‰V6÷µ1¼¥ˆŞ3Ç¨ò`/BãK-¹í–ovb5O¿¡ƒÆ	”4{»›WZğİ"ÌÏ¨ òÀ/‚àC-Šî<gŠR=ïb NÁ§‡Òídy‚t.:å^LÇ«“ûitZ8ß‘Ãd‹Z8ß’Âob#NË§»Ñ™çTPúàAL…©õH>³…ªıM¬,èépv"6Í·®°ç¡QÄå™\TËû»˜WPğá!DÅ˜ŸR@ïcI¶e´]¹Í—¯pâ#NÈ§±Ñ¥äÜZÊß½ÁŒ†*ÿt8.bçMS¬ëéyv5y¾…w1G¦ÕbıL¨#òÉ/´á¸E’ŸmCm‹o;a›FY—×sò(.òä,Zêİ}Î¤*ÚÿÜ È° 'ÂÑä%[ÜÚÊŞ¾Æ‡—qj&~Õÿx)böL5«¿ùt9Q”æyWóx*ılh%rß.ÃçŠR>ï…bMI­·í±m¤lÙj×~ó+ú\ÉIµ´½»™/Uàş@€}$zØÑFæ•U|ı0"¢ÌÏ« øÀhs*nüd	X7Ó³é¨tò8-’îmgoS`ëA{†Y|Ö
õ<>‹„:ZLßªÃÿ‰4¸!Ç`“Biv#6Ë·º±Ÿ§AÑ…æUJı½Œ.(æğT"úÍ¬@èq%ŞvÄ7™³V¨÷ğ1#¤ÈØ²Ò®ïåa_DÁ™‡Tû`A]„Ï¡XÆÓ•ë|z
=Kº%İFÍ—¯pá!GÅ’ŸnCg‹S8é‘vf7W³ñ«$øØÑbçNQ¦äÕZüÜ	È4³º©Ÿ÷A1„¦ÕSüè	r6,¶èµs¾)†õ={%^ŞÆÅ—œsK)»õš?^€Ä›Z8Ü’Èo³a«Dû˜QYä×ZğÜ!ÊÄ¿šƒ_Á3†ªı{%PÜàÉBµ¾'†Ñåu^<Å‹;G™’Woóc+Hù°¢|Ì©8ö4c»I›·[°Ù¢ÕÎı¤Ø+Òøìinwe3_¨Âó* şÀ‚l(jñ|'
Ó>ê…|D:›[MÙ¯ÔàùB~$ÙÖvô49»–›wZ1ß§ÀĞ‚âO-¢ìÌkªxı`"BÍ¯ áÁF…–wB2­ íÁn‡fWhòp-"ïÍb¯Ná§DĞšá]EÍŸ¯@áƒF”1{¥ßRÂïb,Né¥wŞ1Ç¤ÚbßNÃ§‹Ò9ï”czJ½O¡,Åë{F•W~ò,éHu²=­Œî)g÷R0î¡dÇ[ØbÓNë¥{ŞÅTœúH±C¥‰Ş5Ç¼‘Šf?Wƒò,8ë{bMY®Ôåù\Ê{¼‰V6÷µ1¼¥ˆŞ3Ç¨ò`/BãK-¹í–ovb5O¿¡ƒÆ	”4{»›WZğİ"ÌÏ¨ òÀ/‚àC-Šî<gŠR=ïb NÁ§‡Òídy‚t.:å^LÇ«“ûitZ8ß‘Ãd‹Z8ß’Âob#NË§»Ñ™çTPúàAL…©õH>³…ªıM¬,èépv"6Í·®°ç¡QÄå™\TËû»˜WPğá!DÅ˜ŸR@ïcI¶e´]¹Í—¯pâ#NÈ§±Ñ¥äÜZÊß½ÁŒ†*ÿt8.bçMS¬ëéyv5y¾…w1G¦ÕbıL¨#òÉ/´á¸E’ŸmCm‹o;a›FY—×sò(.òä,Zêİ}Î¤*ÚÿÜ È° 'ÂÑä%[ÜÚÊŞ¾Æ‡—qj&~Õÿx)böL5«¿ùt9Q”æyWóx*ılh%rß.ÃçŠR>ï…bMI­·í±m¤lÙj×~ó+ú\ÉIµ´½»™/Uàş@€}$zØÑFæ•U|ı0"¢ÌÏ« øÀhs*nüd	X7Ó³é¨tò8-’îmgoS`ëA{†Y|Ö
õ<>‹„:ZLßªÃÿ‰4¸!Ç`“Biv#6Ë·º±Ÿ§AÑ…æUJı½Œ.(æğT"úÍ¬@èq%ŞvÄ7™³V¨÷ğ1#¤ÈØ²Ò®ïåa_DÁ™‡Tû`A]„Ï¡XÆÓ•ë|z
=Kº%İFÍ—¯pá!GÅ’ŸnCg‹S8é‘vf7W³ñ«$øØÑbçNQ¦äÕZüÜ	È4³º©Ÿ÷A1„¦ÕSüè	r6,¶èµs¾)†õ={%^ŞÆÅ—œsK)»õš?^€Ä›Z8Ü’Èo³a«Dû˜QYä×ZğÜ!ÊÄ¿šƒ_Á3†ªı{%PÜàÉBµ¾'†Ñåu^<Å‹;G™’Woóc+Hù°¢|Ì©8ö4c»I›·[°Ù¢ÕÎı¤Ø+Òøìinwe3_¨Âó* şÀ‚l(jñ|'
Ó>ê…|D:›[MÙ¯ÔàùB~$ÙÖvô49»–›wZ1ß§ÀĞ‚âO-¢ìÌkªxı`"BÍ¯ áÁF…–wB2­ íÁn‡fWhòp-"ïÍb¯Ná§DĞšá]EÍŸ¯@áƒF”1{¥ßRÂïb,Né¥wŞ1Ç¤ÚbßNÃ§‹Ò9ï”czJ½O¡,Åë{F•W~ò,éHu²=­Œî)g÷R0î¡dÇ[ØbÓNë¥{ŞÅTœúH±C¥‰Ş5Ç¼‘Šf?Wƒò,8ë{bMY®Ôåù\Ê{¼‰V6÷µ1¼¥ˆŞ3Ç¨ò`/BãK-¹í–ovb5O¿¡ƒÆ	”4{»›WZğİ"ÌÏ¨ òÀ/‚àC-Šî<gŠR=ïb NÁ§‡Òídy‚t.:å^LÇ«“ûitZ8ß‘Ãd‹Z8ß’Âob#NË§»Ñ™çTPúàAL…©õH>³…ªıM¬,èépv"6Í·®°ç¡QÄå™\TËû»˜WPğá!DÅ˜ŸR@ïcI¶e´]¹Í—¯pâ#NÈ§±Ñ¥äÜZÊß½ÁŒ†*ÿt8.bçMS¬ëéyv5y¾…w1G¦ÕbıL¨#òÉ/´á¸E’ŸmCm‹o;a›FY—×sò(.òä,Zêİ}Î¤*ÚÿÜ È° 'ÂÑä%[ÜÚÊŞ¾Æ‡—qj&~Õÿx)böL5«¿ùt9Q”æyWóx*ılh%rß.ÃçŠR>ï…bMI­·í±m¤lÙj×~ó+ú\ÉIµ´½»™/Uàş@€}$zØÑFæ•U|ı0"¢ÌÏ« øÀhs*nüd	X7Ó³é¨tò8-’îmgoS`ëA{†Y|Ö
õ<>‹„:ZLßªÃÿ‰4¸!Ç`“Biv#6Ë·º±Ÿ§AÑ…æUJı½Œ.(æğT"úÍ¬@èq%ŞvÄ7™³V¨÷ğ1#¤ÈØ²Ò®ïåa_DÁ™‡Tû`A]„Ï¡XÆÓ•ë|z
=Kº%İFÍ—¯pá!GÅ’ŸnCg‹S8é‘vf7W³ñ«$øØÑbçNQ¦äÕZüÜ	È4³º©Ÿ÷A1„¦ÕSüè	r6,¶èµs¾)†õ={%^ŞÆÅ—œsK)»õš?^€Ä›Z8Ü’Èo³a«Dû˜QYä×ZğÜ!ÊÄ¿šƒ_Á3†ªı{%PÜàÉBµ¾'†Ñåu^<Å‹;G™’Woóc+Hù°¢|Ì©8ö4c»I›·[°Ù¢ÕÎı¤Ø+Òøìinwe3_¨Âó* şÀ‚l(jñ|'
Ó>ê…|D:›[MÙ¯ÔàùB~$ÙÖvô49»–›wZ1ß§ÀĞ‚âO-¢ìÌkªxı`"BÍ¯ áÁF…–wB2­ íÁn‡fWhòp-"ïÍb¯Ná§DĞšá]EÍŸ¯@áƒF”1{¥ßRÂïb,Né¥wŞ1Ç¤ÚbßNÃ§‹Ò9ï”czJ½O¡,Åë{F•W~ò,éHu²=­Œî)g÷R0î¡dÇ[ØbÓNë¥{ŞÅTœúH±C¥‰Ş5Ç¼‘Šf?Wƒò,8ë{bMY®Ôåù\Ê{¼‰V6÷µ1¼¥ˆŞ3Ç¨ò`/BãK-¹í–ovb5O¿¡ƒÆ	”4{»›WZğİ"ÌÏ¨ òÀ/‚àC-Šî<gŠR=ïb NÁ§‡Òídy‚t.:å^LÇ«“ûitZ8ß‘Ãd‹Z8ß’Âob#NË§»Ñ™çTPúàAL…©õH>³…ªıM¬,èépv"6Í·®°ç¡QÄå™\TËû»˜WPğá!DÅ˜ŸR@ïcI¶e´]¹Í—¯pâ#NÈ§±Ñ¥äÜZÊß½ÁŒ†*ÿt8.bçMS¬ëéyv5y¾…w1G¦ÕbıL¨#òÉ/´á¸E’ŸmCm‹o;a›FY—×sò(.òä,Zêİ}Î¤*ÚÿÜ È° 'ÂÑä%[ÜÚÊŞ¾Æ‡—qj&~Õÿx)böL5«¿ùt9Q”æyWóx*ılh%rß.ÃçŠR>ï…bMI­·í±m¤lÙj×~ó+ú\ÉIµ´½»™/Uàş@€}$zØÑFæ•U|ı0"¢ÌÏ« øÀhs*nüd	X7Ó³é¨tò8-’îmgoS`ëA{†Y|Ö
õ<>‹„:ZLßªÃÿ‰4¸!Ç`“Biv#6Ë·º±Ÿ§AÑ…æUJı½Œ.(æğT"úÍ¬@èq%ŞvÄ7™³V¨÷ğ1#¤ÈØ²Ò®ïåa_DÁ™‡Tû`A]„Ï¡XÆÓ•ë|z
=Kº%İFÍ—¯pá!GÅ’ŸnCg‹S8é‘vf7W³ñ«$øØÑbçNQ¦äÕZüÜ	È4³º©Ÿ÷A1„¦ÕSüè	r6,¶èµs¾)†õ={%^ŞÆÅ—œsK)»õš?^€Ä›Z8Ü’Èo³a«Dû˜QYä×ZğÜ!ÊÄ¿šƒ_Á3†ªı{%PÜàÉBµ¾'†Ñåu^<Å‹;G™’Woóc+Hù°¢|Ì©8ö4c»I›·[°Ù¢ÕÎı¤Ø+Òøìinwe3_¨Âó* şÀ‚l(jñ|'
Ó>ê…|D:›[MÙ¯ÔàùB~$ÙÖvô49»–›wZ1ß§ÀĞ‚âO-¢ìÌkªxı`"BÍ¯ áÁF…–wB2­ íÁn‡fWhòp-"ïÍb¯Ná§DĞšá]EÍŸ¯@áƒF”1{¥ßRÂïb,Né¥wŞ1Ç¤ÚbßNÃ§‹Ò9ï”czJ½O¡,Åë{F•W~ò,éHu²=­Œî)g÷R0î¡dÇ[ØbÓNë¥{ŞÅTœúH±C¥‰Ş5Ç¼‘Šf?Wƒò,8ë{bMY®Ôåù\Ê{¼‰V6÷µ1¼¥ˆŞ3Ç¨ò`/BãK-¹í–ovb5O¿¡ƒÆ	”4{»›WZğİ"ÌÏ¨ òÀ/‚àC-Šî<gŠR=ïb NÁ§‡Òídy‚t.:å^LÇ«“ûitZ8ß‘Ãd‹Z8ß’Âob#NË§»Ñ™çTPúàAL…©õH>³…ªıM¬,èépv"6Í·®°ç¡QÄå™\TËû»˜WPğá!DÅ˜ŸR@ïcI¶e´]¹Í—¯pâ#NÈ§±Ñ¥äÜZÊß½ÁŒ†*ÿt8.bçMS¬ëéyv5y¾…w1G¦ÕbıL¨#òÉ/´á¸E’ŸmCm‹o;a›FY—×sò(.òä,Zêİ}Î¤*ÚÿÜ È° 'ÂÑä%[ÜÚÊŞ¾Æ‡—qj&~Õÿx)böL5«¿ùt9Q”æyWóx*ılh%rß.ÃçŠR>ï…bMI­·í±m¤lÙj×~ó+ú\ÉIµ´½»™/Uàş@€}$zØÑFæ•U|ı0"¢ÌÏ« øÀhs*nüd	X7Ó³é¨tò8-’îmgoS`ëA{†Y|Ö
õ<>‹„:ZLßªÃÿ‰4¸!Ç`“Biv#6Ë·º±Ÿ§AÑ…æUJı½Œ.(æğT"úÍ¬@èq%ŞvÄ7™³V¨÷ğ1#¤ÈØ²Ò®ïåa_DÁ™‡Tû`A]„Ï¡XÆÓ•ë|z
=Kº%İFÍ—¯pá!GÅ’ŸnCg‹S8é‘vf7W³ñ«$øØÑbçNQ¦äÕZüÜ	È4³º©Ÿ÷A1„¦ÕSüè	r6,¶èµs¾)†õ={%^ŞÆÅ—œsK)»õš?^€Ä›Z8Ü’Èo³a«Dû˜QYä×ZğÜ!ÊÄ¿šƒ_Á3†ªı{%PÜàÉBµ¾'†Ñåu^<Å‹;G™’Woóc+Hù°¢|Ì©8ö4c»I›·[°Ù¢ÕÎı¤Ø+Òøìinwe3_¨Âó* şÀ‚l(jñ|'
Ó>ê…|D:›[MÙ¯ÔàùB~$ÙÖvô49»–›wZ1ß§ÀĞ‚âO-¢ìÌkªxı`"BÍ¯ áÁF…–wB2­ íÁn‡fWhòp-"ïÍb¯Ná§DĞšá]EÍŸ¯@áƒF”1{¥ßRÂïb,Né¥wŞ1Ç¤ÚbßNÃ§‹Ò9ï”czJ½O¡,Åë{F•W~ò,éHu²=­Œî)g÷R0î¡dÇ[ØbÓNë¥{ŞÅTœúH±C¥‰Ş5Ç¼‘Šf?Wƒò,8ë{bMY®Ôåù\Ê{¼‰V6÷µ1¼¥ˆŞ3Ç¨ò`/BãK-¹í–ovb5O¿¡ƒÆ	”4{»›WZğİ"ÌÏ¨ òÀ/‚àC-Šî<gŠR=ïb NÁ§‡Òídy‚t.:å^LÇ«“ûitZ8ß‘Ãd‹Z8ß’Âob#NË§»Ñ™çTPúàAL…©õH>³…ªıM¬,èépv"6Í·®°ç¡QÄå™\TËû»˜WPğá!DÅ˜ŸR@ïcI¶e´]¹Í—¯pâ#NÈ§±Ñ¥äÜZÊß½ÁŒ†*ÿt8.bçMS¬ëéyv5y¾…w1G¦ÕbıL¨#òÉ/´á¸E’ŸmCm‹o;a›FY—×sò(.òä,Zêİ}Î¤*ÚÿÜ È° 'ÂÑä%[ÜÚÊŞ¾Æ‡—qj&~Õÿx)böL5«¿ùt9Q”æyWóx*ılh%rß.ÃçŠR>ï…bMI­·í±m¤lÙj×~ó+ú\ÉIµ´½»™/Uàş@€}$zØÑFæ•U|ı0"¢ÌÏ« øÀhs*nüd	X7Ó³é¨tò8-’îmgoS`ëA{†Y|Ö
õ<>‹„:ZLßªÃÿ‰4¸!Ç`“Biv#6Ë·º±Ÿ§AÑ…æUJı½Œ.(æğT"úÍ¬@èq%ŞvÄ7™³V¨÷ğ1#¤ÈØ²Ò®ïåa_DÁ™‡Tû`A]„Ï¡XÆÓ•ë|z
=Kº%İFÍ—¯pá!GÅ’ŸnCg‹S8é‘vf7W³ñ«$øØÑbçNQ¦äÕZüÜ	È4³º©Ÿ÷A1„¦ÕSüè	r6,¶èµs¾)†õ={%^ŞÆÅ—œsK)»õš?^€Ä›Z8Ü’Èo³a«Dû˜QYä×ZğÜ!ÊÄ¿šƒ_Á3†ªı{%PÜàÉBµ¾'†Ñåu^<Å‹;G™’Woóc+Hù°¢|Ì©8ö4c»I›·[°Ù¢ÕÎı¤Ø+Òøìinwe3_¨Âó* şÀ‚l(jñ|'
Ó>ê…|D:›[MÙ¯ÔàùB~$ÙÖvô49»–›wZ1ß§ÀĞ‚âO-¢ìÌkªxı`"BÍ¯ áÁF…–wB2­ íÁn‡fWhòp-"ïÍb¯Ná§DĞšá]EÍŸ¯@áƒF”1{¥ßRÂïb,Né¥wŞ1Ç¤ÚbßNÃ§‹Ò9ï”czJ½O¡,Åë{F•W~ò,éHu²=­Œî)g÷R0î¡dÇ[ØbÓNë¥{ŞÅTœúH±C¥‰Ş5Ç¼‘Šf?Wƒò,8ë{bMY®Ôåù\Ê{¼‰V6÷µ1¼¥ˆŞ3Ç¨ò`/BãK-¹í–ovb5O¿¡ƒÆ	”4{»›WZğİ"ÌÏ¨ òÀ/‚àC-Šî<gŠR=ïb NÁ§‡Òídy‚t.:å^LÇ«“ûitZ8ß‘Ãd‹Z8ß’Âob#NË§»Ñ™çTPúàAL…©õH>³…ªıM¬,èépv"6Í·®°ç¡QÄå™\TËû»˜WPğá!DÅ˜ŸR@ïcI¶e´]¹Í—¯pâ#NÈ§±Ñ¥äÜZÊß½ÁŒ†*ÿt8.bçMS¬ëéyv5y¾…w1G¦ÕbıL¨#òÉ/´á¸E’ŸmCm‹o;a›FY—×sò(.òä,Zêİ}Î¤*ÚÿÜ È° 'ÂÑä%[ÜÚÊŞ¾Æ‡—qj&~Õÿx)böL5«¿ùt9Q”æyWóx*ılh%rß.ÃçŠR>ï…bMI­·í±m¤lÙj×~ó+ú\ÉIµ´½»™/Uàş@€}$zØÑFæ•U|ı0"¢ÌÏ« øÀhs*nüd	X7Ó³é¨tò8-’îmgoS`ëA{†Y|Ö
õ<>‹„:ZLßªÃÿ‰4¸!Ç`“Biv#6Ë·º±Ÿ§AÑ…æUJı½Œ.(æğT"úÍ¬@èq%ŞvÄ7™³V¨÷ğ1#¤ÈØ²Ò®ïåa_DÁ™‡Tû`A]„Ï¡XÆÓ•ë|z
=Kº%İFÍ—¯pá!GÅ’ŸnCg‹S8é‘vf7W³ñ«$øØÑbçNQ¦äÕZüÜ	È4³º©Ÿ÷A1„¦ÕSüè	r6,¶èµs¾)†õ={%^ŞÆÅ—œsK)»õš?^€Ä›Z8Ü’Èo³a«Dû˜QYä×ZğÜ!ÊÄ¿šƒ_Á3†ªı{%PÜàÉBµ¾'†Ñåu^<Å‹;G™’Woóc+Hù°¢|Ì©8ö4c»I›·[°Ù¢ÕÎı¤Ø+Òøìinwe3_¨Âó* şÀ‚l(jñ|'
Ó>ê…|D:›[MÙ¯ÔàùB~$ÙÖvô49»–›wZ1ß§ÀĞ‚âO-¢ìÌkªxı`"BÍ¯ áÁF…–wB2­ íÁn‡fWhòp-"ïÍb¯Ná§DĞšá]EÍŸ¯@áƒF”1{¥ßRÂïb,Né¥wŞ1Ç¤ÚbßNÃ§‹Ò9ï”czJ½O¡,Åë{F•W~ò,éHu²=­Œî)g÷R0î¡dÇ[ØbÓNë¥{ŞÅTœúH±C¥‰Ş5Ç¼‘Šf?Wƒò,8ë{bMY®Ôåù\Ê{¼‰V6÷µ1¼¥ˆŞ3Ç¨ò`/BãK-¹í–ovb5O¿¡ƒÆ	”4{»›WZğİ"ÌÏ¨ òÀ/‚àC-Šî<gŠR=ïb NÁ§‡Òídy‚t.:å^LÇ«“ûitZ8ß‘Ãd‹Z8ß’Âob#NË§»Ñ™çTPúàAL…©õH>³…ªıM¬,èépv"6Í·®°ç¡QÄå™\TËû»˜WPğá!DÅ˜ŸR@ïcI¶e´]¹Í—¯pâ#NÈ§±Ñ¥äÜZÊß½ÁŒ†*ÿt8.bçMS¬ëéyv5y¾…w1G¦ÕbıL¨#òÉ/´á¸E’ŸmCm‹o;a›FY—×sò(.òä,Zêİ}Î¤*ÚÿÜ È° 'ÂÑä%[ÜÚÊŞ¾Æ‡—qj&~Õÿx)böL5«¿ùt9Q”æyWóx*ılh%rß.ÃçŠR>ï…bMI­·í±m¤lÙj×~ó+ú\ÉIµ´½»™/Uàş@€}$zØÑFæ•U|ı0"¢ÌÏ« øÀhs*nüd	X7Ó³é¨tò8-’îmgoS`ëA{†Y|Ö
õ<>‹„:ZLßªÃÿ‰4¸!Ç`“Biv#6Ë·º±Ÿ§AÑ…æUJı½Œ.(æğT"úÍ¬@èq%ŞvÄ7™³V¨÷ğ1#¤ÈØ²Ò®ïåa_DÁ™‡Tû`A]„Ï¡XÆÓ•ë|z
=Kº%İFÍ—¯pá!GÅ’ŸnCg‹S8é‘vf7W³ñ«$øØÑbçNQ¦äÕZüÜ	È4³º©Ÿ÷A1„¦ÕSüè	r6,¶èµs¾)†õ={%^ŞÆÅ—œsK)»õš?^€Ä›Z8Ü’Èo³a«Dû˜QYä×ZğÜ!ÊÄ¿šƒ_Á3†ªı{%PÜàÉBµ¾'†Ñåu^<Å‹;G™’Woóc+Hù°¢|Ì©8ö4c»I›·[°Ù¢ÕÎı¤Ø+Òøìinwe3_¨Âó* şÀ‚l(jñ|'
Ó>ê…|D:›[MÙ¯ÔàùB~$ÙÖvô49»–›wZ1ß§ÀĞ‚âO-¢ìÌkªxı`"BÍ¯ áÁF…–wB2­ íÁn‡fWhòp-"ïÍb¯Ná§DĞšá]EÍŸ¯@áƒF”1{¥ßRÂïb,Né¥wŞ1Ç¤ÚbßNÃ§‹Ò9ï”czJ½O¡,Åë{F•W~ò,éHu²=­Œî)g÷R0î¡dÇ[ØbÓNë¥{ŞÅTœúH±C¥‰Ş5Ç¼‘Šf?Wƒò,8ë{bMY®Ôåù\Ê{¼‰V6÷µ1¼¥ˆŞ3Ç¨ò`/BãK-¹í–ovb5O¿¡ƒÆ	”4{»›WZğİ"ÌÏ¨ òÀ/‚àC-Šî<gŠR=ïb NÁ§‡Òídy‚t.:å^LÇ«“ûitZ8ß‘Ãd‹Z8ß’Âob#NË§»Ñ™çTPúàAL…©õH>³…ªıM¬,èépv"6Í·®°ç¡QÄå™\TËû»˜WPğá!DÅ˜ŸR@ïcI¶e´]¹Í—¯pâ#NÈ§±Ñ¥äÜZÊß½ÁŒ†*ÿt8.bçMS¬ëéyv5y¾…w1G¦ÕbıL¨#òÉ/´á¸E’ŸmCm‹o;a›FY—×sò(.òä,Zêİ}Î¤*ÚÿÜ È° 'ÂÑä%[ÜÚÊŞ¾Æ‡—qj&~Õÿx)böL5«¿ùt9Q”æyWóx*ılh%rß.ÃçŠR>ï…bMI­·í±m¤lÙj×~ó+ú\ÉIµ´½»™/Uàş@€}$zØÑFæ•U|ı0"¢ÌÏ« øÀhs*nüd	X7Ó³é¨tò8-’îmgoS`ëA{†Y|Ö
õ<>‹„:ZLßªÃÿ‰4¸!Ç`“Biv#6Ë·º±Ÿ§AÑ…æUJı½Œ.(æğT"úÍ¬@èq%ŞvÄ7™³V¨÷ğ1#¤ÈØ²Ò®ïåa_DÁ™‡Tû`A]„Ï¡XÆÓ•ë|z
=Kº%İFÍ—¯pá!GÅ’ŸnCg‹S8é‘vf7W³ñ«$øØÑbçNQ¦äÕZüÜ	È4³º©Ÿ÷A1„¦ÕSüè	r6,¶èµs¾)†õ={%^ŞÆÅ—œsK)»õš?^€Ä›Z8Ü’Èo³a«Dû˜QYä×ZğÜ!ÊÄ¿šƒ_Á3†ªı{%PÜàÉBµ¾'†Ñåu^<Å‹;G™’Woóc+Hù°¢|Ì©8ö4c»I›·[°Ù¢ÕÎı¤Ø+Òøìinwe3_¨Âó* şÀ‚l(jñ|'
Ó>ê…|D:›[MÙ¯ÔàùB~$ÙÖvô49»–›wZ1ß§ÀĞ‚âO-¢ìÌkªxı`"BÍ¯ áÁF…–wB2­ íÁn‡fWhòp-"ïÍb¯Ná§DĞšá]EÍŸ¯@áƒF”1{¥ßRÂïb,Né¥wŞ1Ç¤ÚbßNÃ§‹Ò9ï”czJ½O¡,Åë{F•W~ò,éHu²=­Œî)g÷R0î¡dÇ[ØbÓNë¥{ŞÅTœúH±C¥‰Ş5Ç¼‘Šf?Wƒò,8ë{bMY®Ôåù\Ê{¼‰V6÷µ1¼¥ˆŞ3Ç¨ò`/BãK-¹í–ovb5O¿¡ƒÆ	”4{»›WZğİ"ÌÏ¨ òÀ/‚àC-Šî<gŠR=ïb NÁ§‡Òídy‚t.:å^LÇ«“ûitZ8ß‘Ãd‹Z8ß’Âob#NË§»Ñ™çTPúàAL…©õH>³…ªıM¬,èépv"6Í·®°ç¡QÄå™\TËû»˜WPğá!DÅ˜ŸR@ïcI¶e´]¹Í—¯pâ#NÈ§±Ñ¥äÜZÊß½ÁŒ†*ÿt8.bçMS¬ëéyv5y¾…w1G¦ÕbıL¨#òÉ/´á¸E’ŸmCm‹o;a›FY—×sò(.òä,Zêİ}Î¤*ÚÿÜ È° 'ÂÑä%[ÜÚÊŞ¾Æ‡—qj&~Õÿx)böL5«¿ùt9Q”æyWóx*ılh%rß.ÃçŠR>ï…bMI­·í±m¤lÙj×~ó+ú\ÉIµ´½»™/Uàş@€}$zØÑFæ•U|ı0"¢ÌÏ« øÀhs*nüd	X7Ó³é¨tò8-’îmgoS`ëA{†Y|Ö
õ<>‹„:ZLßªÃÿ‰4¸!Ç`“Biv#6Ë·º±Ÿ§AÑ…æUJı½Œ.(æğT"úÍ¬@èq%ŞvÄ7™³V¨÷ğ1#¤ÈØ²Ò®ïåa_DÁ™‡Tû`A]„Ï¡XÆÓ•ë|z
=Kº%İFÍ—¯pá!GÅ’ŸnCg‹S8é‘vf7W³ñ«$øØÑbçNQ¦äÕZüÜ	È4³º©Ÿ÷A1„¦ÕSüè	r6,¶èµs¾)†õ={%^ŞÆÅ—œsK)»õš?^€Ä›Z8Ü’Èo³a«Dû˜QYä×ZğÜ!ÊÄ¿šƒ_Á3†ªı{%PÜàÉBµ¾'†Ñåu^<Å‹;G™’Woóc+Hù°¢|Ì©8ö4c»I›·[°Ù¢ÕÎı¤Ø+Òøìinwe3_¨Âó* şÀ‚l(jñ|'
Ó>ê…|D:›[MÙ¯ÔàùB~$ÙÖvô49»–›wZ1ß§ÀĞ‚âO-¢ìÌkªxı`"BÍ¯ áÁF…–wB2­ íÁn‡fWhòp-"ïÍb¯Ná§DĞšá]EÍŸ¯@áƒF”1{¥ßRÂïb,Né¥wŞ1Ç¤ÚbßNÃ§‹Ò9ï”czJ½O¡,Åë{F•W~ò,éHu²=­Œî)g÷R0î¡dÇ[ØbÓNë¥{ŞÅTœúH±C¥‰Ş5Ç¼‘Šf?Wƒò,8ë{bMY®Ôåù\Ê{¼‰V6÷µ1¼¥ˆŞ3Ç¨ò`/BãK-¹í–ovb5O¿¡ƒÆ	”4{»›WZğİ"ÌÏ¨ òÀ/‚àC-Šî<gŠR=ïb NÁ§‡Òídy‚t.:å^LÇ«“ûitZ8ß‘Ãd‹Z8ß’Âob#NË§»Ñ™çTPúàAL…©õH>³…ªıM¬,èépv"6Í·®°ç¡QÄå™\TËû»˜WPğá!DÅ˜ŸR@ïcI¶e´]¹Í—¯pâ#NÈ§±Ñ¥äÜZÊß½ÁŒ†*ÿt8.bçMS¬ëéyv5y¾…w1G¦ÕbıL¨#òÉ/´á¸E’ŸmCm‹o;a›FY—×sò(.òä,Zêİ}Î¤*ÚÿÜ È° 'ÂÑä%[ÜÚÊŞ¾Æ‡—qj&~Õÿx)böL5«¿ùt9Q”æyWóx*ılh%rß.ÃçŠR>ï…bMI­·í±m¤lÙj×~ó+ú\ÉIµ´½»™/Uàş@€}$zØÑFæ•U|ı0"¢ÌÏ« øÀhs*nüd	X7Ó³é¨tò8-’îmgoS`ëA{†Y|Ö
õ<>‹„:ZLßªÃÿ‰4¸!Ç`“Biv#6Ë·º±Ÿ§AÑ…æUJı½Œ.(æğT"úÍ¬@èq%ŞvÄ7™³V¨÷ğ1#¤ÈØ²Ò®ïåa_DÁ™‡Tû`A]„Ï¡XÆÓ•ë|z
=Kº%İFÍ—¯pá!GÅ’ŸnCg‹S8é‘vf7W³ñ«$øØÑbçNQ¦äÕZüÜ	È4³º©Ÿ÷A1„¦ÕSüè	r6,¶èµs¾)†õ={%^ŞÆÅ—œsK)»õš?^€Ä›Z8Ü’Èo³a«Dû˜QYä×ZğÜ!ÊÄ¿šƒ_Á3†ªı{%PÜàÉBµ¾'†Ñåu^<Å‹;G™’Woóc+Hù°¢|Ì©8ö4c»I›·[°Ù¢ÕÎı¤Ø+Òøìinwe3_¨Âó* şÀ‚l(jñ|'
Ó>ê…|D:›[MÙ¯ÔàùB~$ÙÖvô49»–›wZ1ß§ÀĞ‚âO-¢ìÌkªxı`"BÍ¯ áÁF…–wB2­ íÁn‡fWhòp-"ïÍb¯Ná§DĞšá]EÍŸ¯@áƒF”1{¥ßRÂïb,Né¥wŞ1Ç¤ÚbßNÃ§‹Ò9ï”czJ½O¡,Åë{F•W~ò,éHu²=­Œî)g÷R0î¡dÇ[ØbÓNë¥{ŞÅTœúH±C¥‰Ş5Ç¼‘Šf?Wƒò,8ë{bMY®Ôåù\Ê{¼‰V6÷µ1¼¥ˆŞ3Ç¨ò`/BãK-¹í–ovb5O¿¡ƒÆ	”4{»›WZğİ"ÌÏ¨ òÀ/‚àC-Šî<gŠR=ïb NÁ§‡Òídy‚t.:å^LÇ«“ûitZ8ß‘Ãd‹Z8ß’Âob#NË§»Ñ™çTPúàAL…©õH>³…ªıM¬,èépv"6Í·®°ç¡QÄå™\TËû»˜WPğá!DÅ˜ŸR@ïcI¶e´]¹Í—¯pâ#NÈ§±Ñ¥äÜZÊß½ÁŒ†*ÿt8.bçMS¬ëéyv5y¾…w1G¦ÕbıL¨#òÉ/´á¸E’ŸmCm‹o;a›FY—×sò(.òä,Zêİ}Î¤*ÚÿÜ È° 'ÂÑä%[ÜÚÊŞ¾Æ‡—qj&~Õÿx)böL5«¿ùt9Q”æyWóx*ılh%rß.ÃçŠR>ï…bMI­·í±m¤lÙj×~ó+ú\ÉIµ´½»™/Uàş@€}$zØÑFæ•U|ı0"¢ÌÏ« øÀhs*nüd	X7Ó³é¨tò8-’îmgoS`ëA{†Y|Ö
õ<>‹„:ZLßªÃÿ‰4¸!Ç`“Biv#6Ë·º±Ÿ§AÑ…æUJı½Œ.(æğT"úÍ¬@èq%ŞvÄ7™³V¨÷ğ1#¤ÈØ²Ò®ïåa_DÁ™‡Tû`A]„Ï¡XÆÓ•ë|z
=Kº%İFÍ—¯pá!GÅ’ŸnCg‹S8é‘vf7W³ñ«$øØÑbçNQ¦äÕZüÜ	È4³º©Ÿ÷A1„¦ÕSüè	r6,¶èµs¾)†õ={%^ŞÆÅ—œsK)»õš?^€Ä›Z8Ü’Èo³a«Dû˜QYä×ZğÜ!ÊÄ¿šƒ_Á3†ªı{%PÜàÉBµ¾'†Ñåu^<Å‹;G™’Woóc+Hù°¢|Ì©8ö4c»I›·[°Ù¢ÕÎı¤Ø+Òøìinwe3_¨Âó* şÀ‚l(jñ|'
Ó>ê…|D:›[MÙ¯ÔàùB~$ÙÖvô49»–›wZ1ß§ÀĞ‚âO-¢ìÌkªxı`"BÍ¯ áÁF…–wB2­ íÁn‡fWhòp-"ïÍb¯Ná§DĞšá]EÍŸ¯@áƒF”1{¥ßRÂïb,Né¥wŞ1Ç¤ÚbßNÃ§‹Ò9ï”czJ½O¡,Åë{F•W~ò,éHu²=­Œî)g÷R0î¡dÇ[ØbÓNë¥{ŞÅTœúH±C¥‰Ş5Ç¼‘Šf?Wƒò,8ë{bMY®Ôåù\Ê{¼‰V6÷µ1¼¥ˆŞ3Ç¨ò`/BãK-¹í–ovb5O¿¡ƒÆ	”4{»›WZğİ"ÌÏ¨ òÀ/‚àC-Šî<gŠR=ïb NÁ§‡Òídy‚t.:å^LÇ«“ûitZ8ß‘Ãd‹Z8ß’Âob#NË§»Ñ™çTPúàAL…©õH>³…ªıM¬,èépv"6Í·®°ç¡QÄå™\TËû»˜WPğá!DÅ˜ŸR@ïcI¶e´]¹Í—¯pâ#NÈ§±Ñ¥äÜZÊß½ÁŒ†*ÿt8.bçMS¬ëéyv5y¾…w1G¦ÕbıL¨#òÉ/´á¸E’ŸmCm‹o;a›FY—×sò(.òä,Zêİ}Î¤*ÚÿÜ È° 'ÂÑä%[ÜÚÊŞ¾Æ‡—qj&~Õÿx)böL5«¿ùt9Q”æyWóx*ılh%rß.ÃçŠR>ï…bMI­·í±m¤lÙj×~ó+ú\ÉIµ´½»™/Uàş@€}$zØÑFæ•U|ı0"¢ÌÏ« øÀhs*nüd	X7Ó³é¨tò8-’îmgoS`ëA{†Y|Ö
õ<>‹„:ZLßªÃÿ‰4¸!Ç`“Biv#6Ë·º±Ÿ§AÑ…æUJı½Œ.(æğT"úÍ¬@èq%ŞvÄ7™³V¨÷ğ1#¤ÈØ²Ò®ïåa_DÁ™‡Tû`A]„Ï¡XÆÓ•ë|z
=Kº%İFÍ—¯pá!GÅ’ŸnCg‹S8é‘vf7W³ñ«$øØÑbçNQ¦äÕZüÜ	È4³º©Ÿ÷A1„¦ÕSüè	r6,¶èµs¾)†õ={%^ŞÆÅ—œsK)»õš?^€Ä›Z8Ü’Èo³a«Dû˜QYä×ZğÜ!ÊÄ¿šƒ_Á3†ªı{%PÜàÉBµ¾'†Ñåu^<Å‹;G™’Woóc+Hù°¢|Ì©8ö4c»I›·[°Ù¢ÕÎı¤Ø+Òøìinwe3_¨Âó* şÀ‚l(jñ|'
Ó>ê…|D:›[MÙ¯ÔàùB~$ÙÖvô49»–›wZ1ß§ÀĞ‚âO-¢ìÌkªxı`"BÍ¯ áÁF…–wB2­ íÁn‡fWhòp-"ïÍb¯Ná§DĞšá]EÍŸ¯@áƒF”1{¥ßRÂïb,Né¥wŞ1Ç¤ÚbßNÃ§‹Ò9ï”czJ½O¡,Åë{F•W~ò,éHu²=­Œî)g÷R0î¡dÇ[ØbÓNë¥{ŞÅTœúH±C¥‰Ş5Ç¼‘Šf?Wƒò,8ë{bMY®Ôåù\Ê{¼‰V6÷µ1¼¥ˆŞ3Ç¨ò`/BãK-¹í–ovb5O¿¡ƒÆ	”4{»›WZğİ"ÌÏ¨ òÀ/‚àC-Šî<gŠR=ïb NÁ§‡Òídy‚t.:å^LÇ«“ûitZ8ß‘Ãd‹Z8ß’Âob#NË§»Ñ™çTPúàAL…©õH>³…ªıM¬,èépv"6Í·®°ç¡QÄå™\TËû»˜WPğá!DÅ˜ŸR@ïcI¶e´]¹Í—¯pâ#NÈ§±Ñ¥äÜZÊß½ÁŒ†*ÿt8.bçMS¬ëéyv5y¾…w1G¦ÕbıL¨#òÉ/´á¸E’ŸmCm‹o;a›FY—×sò(.òä,Zêİ}Î¤*ÚÿÜ È° 'ÂÑä%[ÜÚÊŞ¾Æ‡—qj&~Õÿx)böL5«¿ùt9Q”æyWóx*ılh%rß.ÃçŠR>ï…bMI­·í±m¤lÙj×~ó+ú\ÉIµ´½»™/Uàş@€}$zØÑFæ•U|ı0"¢ÌÏ« øÀhs*nüd	X7Ó³é¨tò8-’îmgoS`ëA{†Y|Ö
õ<>‹„:ZLßªÃÿ‰4¸!Ç`“Biv#6Ë·º±Ÿ§AÑ…æUJı½Œ.(æğT"úÍ¬@èq%ŞvÄ7™³V¨÷ğ1#¤ÈØ²Ò®ïåa_DÁ™‡Tû`A]„Ï¡XÆÓ•ë|z
=Kº%İFÍ—¯pá!GÅ’ŸnCg‹S8é‘vf7W³ñ«$øØÑbçNQ¦äÕZüÜ	È4³º©Ÿ÷A1„¦ÕSüè	r6,¶èµs¾)†õ={%^ŞÆÅ—œsK)»õš?^€Ä›Z8Ü’Èo³a«Dû˜QYä×ZğÜ!ÊÄ¿šƒ_Á3†ªı{%PÜàÉBµ¾'†Ñåu^<Å‹;G™’Woóc+Hù°¢|Ì©8ö4c»I›·[°Ù¢ÕÎı¤Ø+Òøìinwe3_¨Âó* şÀ‚l(jñ|'
Ó>ê…|D:›[MÙ¯ÔàùB~$ÙÖvô49»–›wZ1ß§ÀĞ‚âO-¢ìÌkªxı`"BÍ¯ áÁF…–wB2­ íÁn‡fWhòp-"ïÍb¯Ná§DĞšá]EÍŸ¯@áƒF”1{¥ßRÂïb,Né¥wŞ1Ç¤ÚbßNÃ§‹Ò9ï”czJ½O¡,Åë{F•W~ò,éHu²=­Œî)g÷R0î¡dÇ[ØbÓNë¥{ŞÅTœúH±C¥‰Ş5Ç¼‘Šf?Wƒò,8ë{bMY®Ôåù\Ê{¼‰V6÷µ1¼¥ˆŞ3Ç¨ò`/BãK-¹í–ovb5O¿¡ƒÆ	”4{»›WZğİ"ÌÏ¨ òÀ/‚àC-Šî<gŠR=ïb NÁ§‡Òídy‚t.:å^LÇ«“ûitZ8ß‘Ãd‹Z8ß’Âob#NË§»Ñ™çTPúàAL…©õH>³…ªıM¬,èépv"6Í·®°ç¡QÄå™\TËû»˜WPğá!DÅ˜ŸR@ïcI¶e´]¹Í—¯pâ#NÈ§±Ñ¥äÜZÊß½ÁŒ†*ÿt8.bçMS¬ëéyv5y¾…w1G¦ÕbıL¨#òÉ/´á¸E’ŸmCm‹o;a›FY—×sò(.òä,Zêİ}Î¤*ÚÿÜ È° 'ÂÑä%[ÜÚÊŞ¾Æ‡—qj&~Õÿx)böL5«¿ùt9Q”æyWóx*ılh%rß.ÃçŠR>ï…bMI­·í±m¤lÙj×~ó+ú\ÉIµ´½»™/Uàş@€}$zØÑFæ•U|ı0"¢ÌÏ« øÀhs*nüd	X7Ó³é¨tò8-’îmgoS`ëA{†Y|Ö
õ<>‹„:ZLßªÃÿ‰4¸!Ç`“Biv#6Ë·º±Ÿ§AÑ…æUJı½Œ.(æğT"úÍ¬@èq%ŞvÄ7™³V¨÷ğ1#¤ÈØ²Ò®ïåa_DÁ™‡Tû`A]„Ï¡XÆÓ•ë|z
=Kº%İFÍ—¯pá!GÅ’ŸnCg‹S8é‘vf7W³ñ«$øØÑbçNQ¦äÕZüÜ	È4³º©Ÿ÷A1„¦ÕSüè	r6,¶èµs¾)†õ={%^ŞÆÅ—œsK)»õš?^€Ä›Z8Ü’Èo³a«Dû˜QYä×ZğÜ!ÊÄ¿šƒ_Á3†ªı{%PÜàÉBµ¾'†Ñåu^<Å‹;G™’Woóc+Hù°¢|Ì©8ö4c»I›·[°Ù¢ÕÎı¤Ø+Òøìinwe3_¨Âó* şÀ‚l(jñ|'
Ó>ê…|D:›[MÙ¯ÔàùB~$ÙÖvô49»–›wZ1ß§ÀĞ‚âO-¢ìÌkªxı`"BÍ¯ áÁF…–wB2­ íÁn‡fWhòp-"ïÍb¯Ná§DĞšá]EÍŸ¯@áƒF”1{¥ßRÂïb,Né¥wŞ1Ç¤ÚbßNÃ§‹Ò9ï”czJ½O¡,Åë{F•W~ò,éHu²=­Œî)g÷R0î¡dÇ[ØbÓNë¥{ŞÅTœúH±C¥‰Ş5Ç¼‘Šf?Wƒò,8ë{bMY®Ôåù\Ê{¼‰V6÷µ1¼¥ˆŞ3Ç¨ò`/BãK-¹í–ovb5O¿¡ƒÆ	”4{»›WZğİ"ÌÏ¨ òÀ/‚àC-Šî<gŠR=ïb NÁ§‡Òíd v:)~XªØÜ¯«\PjúvM
Œ'[gæŒ/Pù¡H)Å‚W˜6És~4çûh&+÷§1˜óIhëœÇË~]µêáoM)Ôè
)@¶+¸ü´R¸¥½Öš]TÉÕëÂwµõw ÒcOl´}é@u¸oÚqÒ5 {Èà¯¢-ˆMÇ«‘ÎcğF…c)Nï‚aD><b½JŒ‰.ÉâƒH…6škS`ÌAî ïç<'àVF¿•Ï«,Íí¯ZæÎ{“.nÿCÍ#&ïŸ/˜'šÍ½Mm)ÌªÔ*¹Ì2*„÷—¥TÂ·ÏfO`¡Qï¼.m0PJ«º²¡ıC¾”:#ÓÌc bÙŠ"¤,:r3œŠqnY£×¨ìÉ‡&K€‘¥¿áÛbúv²ß‹ó8rË$;À¦Úñı>Àµ†•Nt-²#öÖ©1–¹–9Òşa+EòøÀ¯dÛÌlîw‡‚ºR¯¼éÖm¾vŠÒ¸%¨Âo€Ô´³ÈªÖIÀ¦=ÁJM¢N-FZ(ÿqíšÊû›ULO,(Íïãs[P2¯¡bã|KP¡âÜs’Lm”ábME›§[óÍ#N—£mt>Î™Fñ2¼QõôÒÿ$úÇıpîÀ,×‹6ğªÀaéã]KÅˆr.±	`ü^ëeÂvÁG–|Ë¡Â@Ä™ŸæÄÜ½ÕÀîHé”;v`ls\1öÿ!.újviT$ÎK¡ç‰ICqB;o6Í²„ûDô$•}tVx]îÙÓ"0/L2ˆğ2q¶7XVÏMBOoÚ-ıio™ßùR»®‡à§f€DG¬ég(Ä"­Åì€İ@Ò…X9€„D(­	¦Œe"]Ğy£ÛŸˆx<şvÃÿ—á§Ài¦'Æ•£üÉÏKO¡%ÍôWsüSju%|ê8BH’`pì:ešL„îW(öÈ¶(zª«r„w¶}µAª.ìÎ@ã¿Ô­¹È˜ÕT` ô|"@-& ^‹Ïc„Å?mğÄÎ/d»wa|P§ìŒlí¡s$É;1XßH¶XğfŠG=ÏÁ
¬=îİè×xû&#ÕèèGåÌX\[¼:i6_¶ÄåG{™-oì@|°‡¡IÊ#ãÏj0A­'Tô«*¼Ìõ`ÓşI¸—Ëaì^Êf„ä×_IË¼²"Õ_Hïº9±…BÛ|ªMiñ"Æ¡0î™9~ÙIÆ¹õuÜ•ãOP.úîSHê“j]è‘u£ô×Ø1Ö¿‹×ÒXPÆ¡ŠÅzÈ¶¸îõª¨i­x
ç…ı;>-¬ê§ù˜>
ö\%e`²q\:+>D¤ÂÊÙç©D|3RJ\Ç*wPhÅşhUä¡H)ÄŞÌ;‡1c¶ì5/*¼İeÑá@ñœÇî;Hƒàây/Õò
(Báb „ûùöô”„[AÈÑëÒ3àİm Ò^1î?®"à
ˆ"Ğ/B°¯øñG}¥DÓã‹Õa¾q†b2@­l b-òqÓÎ|lœ¯Â'FÌuIİgBjÑU©±å¨8-Öÿ’ÂãI€¨á§Ãp‘.cõ‘/*çÅ~™OÈ‚ê*UëCåv·«yiÒû(Ğì Šà•üjI`´ºò"²0F;^ óÄâ‡®òš±‡wwİRÔpÛ°.,8rØ™z%Ğû	Š¼Ãaíóé®°.¼jóË‰÷4}†!?Ö©Ş°ù?8Ã·‡Ôe#ÿ@F¤›Ö”Ç„{Óª-R ğ¿êğH-î"fÎW¥ğß"ÀÏ€¢Ì¨ òÃ/ˆâ0O¢ ÍÃ­ˆì1k§zÒí@m‚nd/ZãİKÍ¸­’ïoc`KA¹‡–ue?_€Â
">Ì‡¨ó`*BıŒ(!òÆ/–ãtJ:¿ƒM	­4î¹d—[pÙ"×Îò¤.ÚçİPÌâ©Nõ§<ĞŠà=CŠ.?ç‚Rì%jÜ~É·²e¬\éÉw¶0·£°ÉS³ÎéòÇîm´È@/5*Gª±¡HGÖıÈ^ÌjºÓ#¸4‚*„0%¨S6Xöµ2—vuë9Ö¥-~{Úuìfïã±ûlÛ ¾l¿¡õºŸç†šˆàö
–5(¤,æN#Ë÷­ã	zîß?b}¹sª •ÌàmÛ(™âì0Û“'ÆğÔ4xšn:çĞhaÂHÙpÊo¡ÙÜ…J$ĞªY;ı/=š‰İß±(šåÈQ!•…f/Zµ4O..o'Ø1ãNİ¤‘¼Ê-Á„~öÏ¤@ô·ëSN‹«dßÉ„*Ş†Ç-â.†Yuô¸YFÛOõª™c_Ë~òÊ³á®ÚRš"ÂuÅÀÀ?Ê`ASœ¨ı¦o|—ëtáÉÕ¼îƒØÉsTe–ëæC'Ärœ5ìø@&'·„¾‘²É†Qœea¦8¨ C½8Lj-À—Ê¸cÛ¶—¬E’¬`bh©È_v÷5W-1pfr ©í¯Û·aÄ`*¶Ç¾@«Íıñ{5k¨!ş*f¥ÈEæµà+"/ã‚\]¬ùñ‘„Pé¾§:èÉ¨QM¯p–aˆ	0+[%3ÌÇ‡ªÙñ[§Ë¦°ùÎÈ4ım}%gY‡HÓ	9`‚gÔç„I—DÀG'Ì½#oİ”Ÿ+ı|Şx*É:%TÃNPõ='¢°.»ú¦F¬|˜bĞe‹EüüÕ´Ì³b=:´‰cğk††è
²
CTfo ü–„àÉÒ=5	äîÿÆÊÙMÆ„xÒT—Õ§a¨‚†ËÀyè,CšVÿØ|õ…ZÂA…«>V/“ª5Şbg=*‚5åZ©gø\ıÌN}åè‰(×˜=Ûı§q^¨½vu3hìËd†ïœ‰Ì\ğH`¶È¹?òC”¢w¿F z>My¿Aä.Tş–Œo•Ş‘Üón‡W+Ÿiµ¦"]¼»Kğ3/=C|øˆ«ØêŠÛ(T«o(ìÓ•y—àÈ!ÁQ[§Nñó‹OäÕj´1ò&ïüZ5ÄCÀˆrMI”l´³ßç1yğ›¶·!ã#AÔVR4zª'fƒÍaéFo˜Â¸éÄÆs?ô'w·¤:ËSäc–‘èL³c8ÏÏ•ÜrÅÍèåê$áfß!á±g¼¡†ãOxX¾5ŞbDåü)s:-Íã |•4¿'ÚØ¦c)İkUu°ëÂÌJX¯¶–¬Åg=
wµ¸Dî«¦N“àô²ò(´ 3"aÿIêT™^{ãBÒÉ’	†Êğ´Š[pİ±_ yîÁ°ÕÑ ¨J×#ª±ƒjë¼N;‘¸ı·î›ËŠ¼¹|{èwÓ{Â	^¥ÿÍn’”íÌ}}2ÅßR‘”²‚ùa;. yúúÂŒµ"í6¡ªÌõÉàOjùnMpãÙşaHÄÒPQ=øÌYv,›¬ôÿè¡À×#DŠQ†	şV¹NÇ&—0z±äÙõIÑkÊæÂs4(ÅJ}šO‚™¸h0/û‰‹geßJ%5BpBÔ‘úI3wå®B´fõ’_ˆ#<*X
–5Á¤‡1—,×Ş?¯º7^[ =š¡Lq–ç Ö£swˆ‘˜­µº«Ø,|™³EuÃ·g[L#oĞ®&[©1‚Ir™XÌq@<¯ÇßàmüÃ¾RZW¡F^üHnU¬!jàÑU§A‡ó(_¬Ñ¸è€ ¾Qõ\½\9H(ôÃ‰+ù[ŠlšîÁ Œİ¥ãÔP›;!EûãïŸE^b>™4ĞUSè¤•øæiõ,îV0Ë+ÅM	ñÎ¯Ù@—a|æ±­°hZ2ˆF™2Ü‹HĞŸWŸ`&Â–×ŒÔı<ü¬ì×‘µ«¯ŞùEX¯àš}.mŸ’^”Û¸’û”Ò™ña}l·‹×9‚‰‰H?ĞîĞb¦-tÏà{{¯ª»<ô1¦ô¤şÏırÎm7Üüİ£óvşÃbÜ M`1äJ¸),9ÁÏÖÄÇHãoş9[ )0˜ğ òÎ’uFçY8E_’ì. ¸~İ!BÂİ^ËcºìØ}Lìñáî}L …§°`™‚ìB¥6ñwwnÒ¾D1ËÊ×¯ öô¡y2S_Hi¾Ù¶e×<Yë¥o^LZœ£MTAq¢6{SïNH>}1@§6\ÛC˜DDÊzŞ¨ÓqŸGê®ân8ÿ`İŸ}QÚIÓLÓT[ä,vHˆäë´>.'ŞÖe‰„`î,Æı œgîuÆ[ÀšêââvõRä{A.@£çÜêæÈ;ro›.Í=Ú‡à³•ÓGMnÁoç,dK<…¾\7’ß*;²cë}Øß8ö‚¥]ÖUØJÎ³ûM©Dä~|­í›´Vÿ&ü‘=ÓĞt;g¹ Ñt* r^8+¬¬[¦ÚRú¡"ÑK7Ìæ7&m+‹LĞjbq‘;9Ÿ›•é®­]R>n';G;—gØúø‰aûˆ<Ï¥h²d‚ Ğ¾FÖ5YFÑ_&m=6F!Ì-÷Î‘ó°daŠö|f.t&×?Ì%ÿ“6ÑèbN@J ¡8Æ÷ÙŸÒm ñ€®H÷±+¥Ùó“`9G(nIŞ¼ÒU5æ€ÏÁi¥+“ğk“c¯Ce!ˆ4!ZF^¦£ ùlRÖ½vÚÙî»“[†¢.‘{®ÉÈ:Ÿ	‚İ`åuE0®°7hÇ.©oHI7XÉ½[îÏEÏŠ(ŠèL™ÁB`ï-@ñ%Ï£ß–º¡<]"–ôx…5-y’v	Ñ5¦g0ŸÈDâ—k½ÉƒÕˆç/Í«ĞJÄ/70K«¯5K¨.bÅªKãÏ¸_¡ÁSï.oÃğ’_3†,'B…ã]ê^Pû‚^9»ÿq.¤ÿ¡ª¾¼^Ö½s«œb·´çb-?ÓÍ”òÄ¿?iŠT¯2!_ikô1O)nzWHqÃ’íRš"ñ¾êËÖO%	|¢
ïÑH{%jÀ`ûƒİu"Ûx¦¡©şv!véf"é™±3e+LÔ|5øJçŸóªOÍq3£×!uÁmüíÜ³¢Ã,Xe°’è	İ õ“†±CRàÀÏˆñoË« Ä¨ÇÜ†ÔRğ6¨“m$Â}¢t|DüŞàA‹×Ò¤±4°q[æü*Ğ:
Õ_2cÓY å§µèÔ ‰è‡Š:Ê ‡!¤5vçØ	’yíE;dë
¥/^ÍÙ¨¢›C~M…•å+,	½é¾f	#™t<uø 7›øD‡ 7œøóUáçË÷“ïO(ÒEi¢v;|{ñà«ª]F«mÖ;úu£xù£ |©ÚÈmé‹|~Eò>F/1˜q²åà~zícœ“:•°fùµª_YÄä|md­lŒõÅ±Gm}fˆÿV‰ç{šŞI\–E÷£HRvùêÎµKŒÚûÆÍø×Iø¾Wˆ¯v”Ø>¯«§¹*Ï<ÙuÍTï~Ì“ÕRû¯~¡KTÊ;*ÚsÍû '¼¥ªªY'CwdZ‰ŠL+f°Eõ¯7FÈ°Ä¸U²$ ƒ¼DÌÎãi~`B¯ñ<É^õYîBúR»¹<èÈşï‘,ª/G ÖhJ«‚)]zcó!¤b""¢#ü7I~¨¾¨`uÇµ2j@–[ì÷B%ÖBà¼.Díd@|ŒÂù|µ<WÊÚ@JFQ½™S[Ä´v?}xÄ\ÌiY–Çéä£ŸIcß.ìäz0IK¦¢ÀN«Áí›ôÄëõd»¯¨ûErõ»±üF#–$=6•kılM6º{åAáw)\!-Oû)ÍOi0^š ğX2zÒš€¤%®±[ğµ*QCª“ê¸é}¯]OÖÎã6mşıå%İ+~‘pÜO-Êijœï,Ì‡*ÉÕÁI?.ZûÊá6Š®+åê[¯‡pd Ş±«Qˆ³”™rvPs¿tÛ5Ù«#&zÃNÿ¡zš4~xB6¦éXŞJX@ÜüÉ%ælCšn{äç­pÄÀ§t®¦eéZrZ<5c4ƒ°Îü¤Êâş`•ü%‚ş6[cú¶ƒJÂR~º4xœ+u¹gGeuà±æı0¿~Ï?Oâ11*ºl˜c£MgW–i“‰÷4ãdK,³´dÌ¦äçôÃNVø}Vÿë'ë‡<3©a3MÅù¸öuÁê;}ÄŸ­¨“,KÕ7¡áç2ïÖ•=8ô äŒ8Ç9^ì^s©jí çx<òyĞKkË(È/S`7Šå	îr¼H^¶‡—e‹ûÛ\¦Ìı±oEúR­lÄ²ã¬!¯sq^„Ó5³ËPqQ>¿†aÒˆıVŸU¿d½Ó¥¯@¤Áélƒ,_‚ñÈp°çû¹4á²(‰#š1Œ’Ñä¥/+P½«Aı)òäŸì`y£dK9ïo"üDä% $4Lú‘¼†Cí-Â=Xø±¡·R0¾1Ã©¿0Ãm³xH¸4âAĞU)`ÍSf½Ü1rO/·«U6O/<Â4j›-ïëÍìPÛ[× ĞW2Ç-K³0¹"KUtø ò‡¢ğ[°â_I7zïëöDŞ –Ü'~B/'^mÖ‰#DE÷ˆj~ö‰ª#³·D—
éÁfºmEbÿù/¡/©<*~½¿6	™Âdˆ{×Ã%nñÉ¬};Bmí-¼}'°Ròp•ìqÒÆÒp÷š	QwgÒ''º*µ¨¤9 RVW8ß)JV#çC_ĞÚhy8Ä!—¬ñ­Ôªoœ’ûÁ_Éb6%ıó&ùkçoG3B ‡ºßa	g¨g6u%ŒÀÄƒ~¤dë5÷‹n6¡ı“Íp1òËg ‘m2YĞôò=MÅ7)²˜/j÷–¡ F›+Hó¬Ö((EúäW5Y=/×â7ëJY¹2jœhÃ±* Ë‘§ŸºÔgŸ2|kok.×RkPÁÎWÕÓúáÎ¦'{˜Ï¯bô.½ë‡à|@+¶dîYÓ94g·æÎ&¦I×Á"ºn|ˆİPbŞM3ë…üÄÿ„çµšœaËü¾fÛj·¥ØæÜåµZa3"b@àí“òg¡¡ZşÃ«î\\º¶jÕ!Î'øc²I§µ¢›ËnvÅ§X—ëÇ#»4„0-!(`I0Í÷îÜÿïß1şWÇHÛÁ>3‰˜Ò%›O˜9¬—uE(ğ<ª–”Ï³Gm@èİ@­ô/2s7A\üûK9mª`: ™7ö¿®0æHá…\_º[D
ÑBcÂM…‘_x´†)ƒ@OrœE	 ‘IíuJ‚Ììƒ«d4FC	l	Øê!E'¥ßJ1Ãç_¼ ôğ3éù^Sır’ƒ,O=m‚W^ŒFxsŒ°¶Ğ.T…äØè«ç¥ò)øq»­Ó2!#WDr şúïÏÕè~’¦dŠÏzºã	‰Ü7Ÿö²õË–şØzßò›'è¹(_JE¹¡)Î#uZxàb‚ÄËh“ Á¤Ç•Ê»ıTçÃ]o}”‰:I-ZÆcG³d;›gMÃ3ñLäx%ÁÙ9kˆÍˆ…¿í¡Š2YÏ 'lh#8
4 „¯¶iñ7E*°W™F¾‡h•1£Š85¦«‰©(Şß-‚XË Ä¼_Ôãä¨åĞ‚vÉY¬Şb\T8$–DCó?ÛP»;Í,%` >‰Ğ+O3
*­Õ‚ÈajõGÁ©_‰–¹¾l·«RHÎùb‘ƒ²a9,o2=Ôn¤6ı‚ˆËâoìØŠ‚x„—» Ì~òÚ÷Üj|Åûé¯\Ê¸W…(-ù&è×]Pšˆ[af½_RfA›.Ã=cG˜Ê	u‰}ÈÅÍ0y°Üê¹:%Sä½)LüìÛrg‡²Ñ8f‚%qbÛhÍ©˜©^x˜½ßNS€W“•Öù'çÂÅ—ìwó3r¼/‰
É–VVƒpú€f^’t‘ıâÈÔ²*tŞÖ>„“;Ç&“D›,ñÕ1[P†Ú1¿’ˆ¸]],;™Fó(c@v¨”Rhu¨F“ëk*…Sş5ÿ§¶¯³Ø³ôFuíÜW"´fİ7î¨Øš Àõ@	SQQm°/¾çê¢Aea	p”\wâ_»6®Æ¬…ÄÊm–i:¢|¨cÒá~y°9…ß~b<·°û ¥Y¨¢=&˜&1Á!¯ñ^E‚Ë4Æ—àv“'Ka=A3ğm$©Ø,írûk‘CšÇÌ¬[‹VZ
 Ò+ÁÅ ß:­Y6«.XœWKOQ5UXÒÂ”Ô@ZÌ×ò/&ë9Pï,·ÎÒ3éŸ©«Wê´9Ææª®‚PÄÚßïîx¶/@ö€lØQ…6½›•Áü³¾¡ûªªû¿K¿ö•UÁh7n‡èïMZ<á¤¿kŒ^AeT§‘§`:ªäÚ>Qæ]ŞEãóı"”N« ¬oÑj`ë¥øú6ûnCš"‚˜ÂÎ=¨=ek‚ 2~ª¢ÙŒ3~ ÎÊvÊµuVŒHs™¼4şÛ¬áä+=ùBK?ÅoLÅ&ÆËšäN®ÉÕA,YÎ%Ç<•.COd·è1¨fß}Ut3dÑçm ÌY—Òëğ½Æ‰ËÔeØK;1İó…”DŞØ×#ÅÁÃ»¶b½rÛÓÌOvB¶;S/xfúf®Q{MKàqù×º¤yKpªÿªÄÿOq.M;Ø©m
p“÷æ¨ÖÛVÿ
¤¦Ùip(Ñ¡ZŸ|áyl²j@»hv<õĞ‘Ü¤XÜ>5ô¡³‘Ñ–f2Ã´°AğŞ;}1ËpÁ¢Ğ‰#qzî#ƒæîÿF$‚ZÔzÚHÍ(]X¼"ıŠù&ŠÔPë{¬mG³5r]³€Ì(¤+Æ¼)ß'˜NG^ÀÒıÉ£leöhÁHßÆ–O/¹Û‘nZsİÈÒíÛKß™ÜO¶§ÖìSŞÎ…c:Ú&ÅM`óDeMÒ“â\Xœ×<˜I;ªß+Í³rğÙF á—ã°Í~¥Óy‡O™(Iº_>˜÷<ÇÍ;ÿÌ‰¹'t'líÍÆŞ¼éW”C‰iF;UÒşz:´7Ù¢Rg¬urŠï¨İ° Xğòå
¹Íƒ¬İm!fáïœRW}«MÆú5i‘‚»)§w?¹wt~%3ßië×á0Nûûòk-xÿuË@Ş6¸¸g ™s‡g·­ÏÊÂå^ÒifU’Ôƒ+ZğéN–|d³l6Ít9ª¹¿õfÔÉºdFÍ¨Dë›:R¤oãß¤eGÕq\Ù àî2«}8*6ráDhÈ&d¬UìòĞ5ğĞşÍ]G4YS*UÂ>Qù+2v¶ÅjMÆvÿÕ¼TÏè…IHŒK‡äÑ›­BÆ8C& 5š…u£¬J|ëòµXÅÂÊƒîòîğ@ÓG64­ïVd½küˆ”³#õA…"#k	v”„cÆ³°Â&;²ÌR0AwçêGšò‚S­†nã^t³GÙ3‚îŠêêÉ¥¿¸M"äºñzaÿ·%EB÷s`(E ¤ ²ã^ìï=‘;t,¥`$™ÄaÇç©’«=è|÷«üöi¹@ MåAclK.ù"…,Ôš…Ø×JNtšâi[¡\+Í¿‡ëPë­*î.Ëùg¬WƒS„K4¬7K®"Çu®óvİ‹¥íB«ö.C4ñ~³òwÿÁ½ö–JÇªo,Å¿˜9éÙRÍ‘ågõHèŒäêªGí;Æ™¹F¯z!º[ ‘ŸÎ²®$ETÆ³gª7O»d6¹¦A% 2Èw\øCç·yß‘ñr3#ªdOùğÕ,ŞìÿÈ òd|:$"½OÄ+³JÃN{Ì÷·¹&©¾› ²#~és!°Š>1>dD…rb¥¡8[–)ïÃVÅ’²üÍboÚƒI^n\šMJmNs—ŠÓe>0âµšÁlig’«Ö&cÔ¿P;;ÅÍ,‹Õ*éËğÓYşB²‹Ï•30F|´w
m‘{ú‘£ß”éPo<*Ç¯8ó;¨JxxŠ¢ö5:ËB?€z?üK™aïÃÒ&80zˆŒ&æ	ºè@™Ke¢VMnÄìÉ†v
Ü7ÈĞÇêRû¯9]+¶şù­×bTÑÎÁ´fñjÈòiyr8ûC´g[$,·Bßş«>µŠÒğ-7yT¢|#QÍ?öó|L×wÛ+Zïÿ´R½#õ8À!ÑcXXˆŒ‘ı,.\Ë«ztZ›òÀ&[œ<µ™ĞÛ}1“¤Èº3zÂ2LyË7¦LçnlÛXüUw±¸SE®s”û×‰V¿îÚOÿ§wf@ÒĞ`¡m€Q>±kuú.|ÿMãšğˆ~œ@$~`’Ê¶Á B¸x—W€¦Í‹cIvl“+–ª
Ş^)eCKÎm+Ûp0¡~8'¢FËS~´Z(IBÑ) ´İµ´ÿÉdsnÌ×Ô2ìCÑy™”>ÎL¡>ı,%M!Çƒ4q4& ­¨[Ì4‘ªiÖ'à†¦í‡ORÿ)‚—î}0‘ŒéRí“Ø¦b³ (’MÉîêç–§z5Õ/8ïÍf}Áx¥ı§RDßPmº·§Ç¿¤ô0Ñ!òGòaÒ7ğ3ûñe Ìæ×¿ùe&†8+tûÅ ñ`Åe*?_d¡ L‡Ô€K4lW‚İL\q­±òz	PaÚƒí ™Æ6'åwäòg'Ã‡›D§#zü¥;±Oª·ÏaPâÛ°ÙêC"§Øæ˜v¸üèOè6åœQfU³84‚{¡º;ğ~â÷ŒşO7A—4•E :…Uy(>ş0şÏê?&É!siq%¯,.¥B]¥é–…ø‰gÄÖT‡Ç19•6áÿ…³!.Mª@HÃ=Ô‘9¥İÅĞl=ü”¸Yu°Õ0‚Æ¤zjúô¿û£İb³{+²»%?.7’7¨éÆ3'jõ¥ñøç¹õ¯œêú<wöjV “(ò€Lµ)ÎÇÀÆŠ"7´E†÷Æ+ê¾u·Í–,­"ªm»D©t_é•e(õôŞ¡J*ºyöşAqçnb>]ÏÈ‚Æ…Á{ÆFnW„¸ª§.f_–™åS hx®5«[i®	äBåG1úÏ†R‘,Ö B¸Y˜  ÷{”|ôÕ‹ƒª=ß™<M>‰L§uÇ£Ö/oŠ+m˜Ø~|2Z²	uPåëJ[åÛqwØÍôë§¦²ÖºÜ­–<¡t¶O91è‹Ë¬~®áoG"õSú»ïoN÷áººùª[L_¦\o}1yœvšêq^íQa¡ã&u–(,\*>jùU‘Blm/~QÊüMíâŞ.ıD>¢’MmdÃ§V;û°’hRÁg/Ü€#=M(ÓØ¨±1ü(+‡yn+;AhçØ-ê)cİ#¯O	Öın9ÒÔÎ‹Wuê‰?ëKY“Ål,Kxzj£œHZT+]xØ}ÅF½¶Œ¥6²©ÍûÀÍgĞà¨3Ş {Æßv ‹U¸'©tZYÔƒ”s&]—‚í!$€rì:–º¹@²¦÷E»tÙ±‹qâÈ•ØÎ—i
€\RÔA²àˆœIÄÉ )Hı«Ã´5F© ¬d¶‹q{cbÜòÂr‡;ÙŒ ¯?cpC£UÃ”Vªªİ¼®„vk¥HŒçş`)Ğxp[Â@ó2â¸õ®"<\yÎ–%RìNtâï&S4–	¾øŸ—H~E~},KyëÔYES#[\ïãQ·
ÆçohÚ‰ì¤†rbªßÒUŸ§»‰tÛE4Ó!äh‹u·sB8”áº«%Ø¯>ñhF[À¤\O-Eg*^OÜHÕ¹Ò£O­ÿàO‘Rd pÉLq¯wza5Ğ†¨å’/i%ÖÍñ>“%òI%ûÏA¹pÓéaQî^qüª›È %—¤ Qdñªc½ƒñ¥&a:	fŠŸõ½‚zæ…8Éğ@€RÕÖÅ?uX3³Íçd‡É,ÊşâW)èŸ¦èYÚ·É±`Êîwèˆim'¯+’›Ã+]áûÎ)n‹
Z†Wj^k™l>!ğS5‘{€Ûl¥
ãV¸DÀõ%”7*‡ºJŒ,ª@
÷*Y_Ìér!›š5?^ø¿]RšÒæy	ª\¯¤2 \Jcî©J—FÕpDúD-2A¯T«’Lù#›ôáÍìÏ—Zœ“ÚÈ]½ó2è,ƒ¡Ûİ”WÀïû6vşŸ Ã$ËŒô!#óš…% dT{
â0×dNÈ	43`œVZ¼¬"ß¹õ¿­İ¸9mñ ‡5.¬IŞ't°¤¡
£oØûÈ|ÑEˆ§gÌ§uê™Ì°FqÒá¹m½‚œg”|8˜DÅ&àâ_š¥¤Rï¹–E¡;±¶+ÀV†‰pR*/–¡@_;‰p®ÑÉy÷ÏöëAûHc%Ç§1°T–*æá”ÛQføtàˆ¤YåDã[%4aÍ¼»É¤ïI?ŒŒoR?ŞåÕá{nM3Çó\¿Éš²ğè>|M†C7*pÃú”ÆjÄ‚ñs¢;¯Ø8Şj#îßê_±êÚ¦‚c¼Ócä4»²jùÒìüšÁíñ}‡xáFÙC€ç&¿Ñîˆ’üyiX7çLş\Âu&d=6ñ…'›Cj¯ÓqZ²š“Z¹íáÇ:NOç4%ØíUwå²v˜ì­»tØÆÎgĞ¸‡É?xóáÉ„ª f7oû•ÿ¬ƒÈ‰ĞøOÏœ˜= ÉwÖ³š­ûg¬GéÁéMRxËl"í¿§ÕgßE¶õÖ]‡™Iç/Ñ:J÷œÎM€ÜÔB~ñn<éå–Ø]şTXùí}@e8ÿ@“ô¼dĞ!_şXÈI¿5<«$Íg©‚ÿµúÔ°¯¹³S»éeØğp¨Œ¿ß·œimÓˆ¾œ”I´“Y×^øø´½óüµRNÒæ¿X ş#·‹ê¥âmö=ÖggØ¸Ê5ÿƒÕt•ÙòuzyéÌh œPü×±*F>î€kpõÁæ=«À'ê]ÄP«w «6ñÔ<xh¿ D]wjF™?öÊ"ª@:>\×ˆS+»í´“É­ÎÅ“)Ù†YZS¶d+fûœcıúY(°®ˆˆ:`y‡İŸ;“ŒcğªûBÖ·Ÿ~€¹Ù«]€f8rF(of|şZ£=V	~ùâ­‡`œ¸1ØŸäúÁj&R:ºƒŞçz‹ PEÕv¸½Hı¿*‰É=  ,˜hµfÈ<(vøüJ	ú¶Št zz.Ø»R—®¥H³DoşnŠà[¦¨:§ÂÖóeÑ´^Ã¥ùÃerÆK%ùõŸDÛ¢^&ÓÇ¹Ø)Qşœ|Tr ãƒ/¸ófÕ§é×n	üÙ‰'F@öL X¢ç°É‹{­Fì[ÄvÕ\«‹zÃ¥›ñÆ!€C#Şï±·RN·E.ó5ZçW…acNBİ%y¢ïÓ¿S©JÓeR	…©hÚˆĞ2óÌY©†°ijÒ“P6»ÊÛáÚá…ıDÒÓpÄ£İ8÷¬±÷µ<áğØ^‹æ1‘å\m¢Óá²Í^[VS÷yq>"ï@–D(œ½GzLSÃ—£†¦¯Ùâ—Ö
éZ¶À8,Kú}ïÜéwàt éÙOÂW­µ,%Y}uS·bã–í±®Áb¡²éU‹¶Á¼êgkÑ8B~Ÿ®¹ˆ òø.ÄÕŠt	]CæúÃÓˆ"ÊFB³LO]©ÿ*,İ:š!Q‘%Ì]xŸ9ˆ”ıÄ'ÊÙ€~U n9õ§¢|:B Énúl×1“TOÊcqM‘)í{Ú9ë&kwë„€ÛXŞNÂ‡¾Ys«Në÷íëÃ+Lªw†Á*±"hûä	Šõ1.« ”¸0f·”qWn>gy-¹IÆNHTŸ&œó11ğ§±)`™°e=…|ÖuQ2LşXÂÀ¥iÏN0œ	¨âgñˆ)Êš{÷P;…&¿‹^•í›*VYdS†¿ùAœ¡'"+æ®û2i0{ËMµnÁÙ†ĞîĞØú­Ä`ã‹:â>À:)õ0Á¼é	5ÒY >„ßùy_uYlÒåë@(İëV2
s6]O@/eR)ÖÓ¼Ñ"öÈq-Ñ3¦âvÿÖ,›Îø«óâ$­3}¡\v„@ØÜn†H†V®—Ô—äTjLú¸L”×ÔšŞïMew~ŞsSIF±F–-Xjí—N(B{¨Y!1S¡}ş¢PÔ¸ %›õ}h¾-€ñ€Ä;Æ/|7ƒ´%Vè—sâöx»z§…ï¿÷ìß=5†#ñŠk‰>êÅdã™‹æÒ½•¬lvÂªMâã#[Ôî.xš¼dÁr -®·„ü\–”©2í¾Âwi8ã ÿ??MKiÃ:|Ÿ ôœÜæÍÂô9hÊT¯fÿ·pWÕQàF)4KYÚ3’P«LÜøo¼dTSşH­")9tXæñ’¶K»ÈŞ‚ÙLrÊ)_}»ä¨­0[q7!<WËÒHË§„•™-Ù,ìh¹«ïWêÙUj£¹B(Ónö˜Š}Kã‹"Ri³İ»¶#ÿGó/-ˆä‡ïÖŞ`Båp*F_‡ öõ–¶c£!¨¿s÷]"Sl¨ºH7˜Dùƒ…ù¡Í›IÕzhş#J±PÉ2R>]Ç0›?k+äË_ql‹„ø®ÂÒmÌöîd·'íjÑ_øe3œ"8Y£?1—ÿ°áå¶Us½Vš!82;…Şai hÙ·}ä‹9š9°¾!]ÃÜ±$8Åø
-õŠX|T­İ!ˆò»|[øqİ”"ãZ1§oİø5 âàj”Ü•é/ ¶D‘ÛŞœZEKÒ:C×ŒûamZ®~™ÕiÁ orÑÍÒ¶Lò­»v>º \ã¡ùÿß²˜S•–Ÿ’Ó ™W hÃG³’*ªJ6÷Óa>)¶o s 1Ğ¼Öf&œ¶­Up,uˆöŒ§_®$ïÍÃoå#¼ùÆ9&£·òLÅòaF±É\Ú^ÉgšÓáA†±œX“¹¥!¸«¥•JÒOŠÍ_V†´V—~ÈÚµsÿ+ìÀ=À÷ğÂĞ“;î%§•íæ`h­„KüÖŒ7{Ègşc/rÔ§uL™àÊ6‡‚ù]&J§óRù†"L6^ÿ2”e˜Y·ĞÃhqû2HÔ•=“ã§Jq\˜›G2ğ&úa(I«'Áò[åü×@•J`ßÑyøegW£ÃCâk*F«À``şÑÏ€¸¦˜pj‹‰Ã8|4¬üì÷Í[I‹YOôÂ_M**Ã9z·æ#.H‹«%Ç\¤âÃóº/G—Åù_×0K»ïQvãö¹ ¢Óİ'g)eïĞJH%MÚÿ6#œ	pg?g§õÿúxRšF@Il_ZùïO ¶`ğpˆØmæƒ‚Et«`±—È¡ÖøAè?¾)Ä…j°¸¤G.–OîÑ?<€á‡øc¹!akëNŞ¿zIİ8ríçW4²ë%æ Ü¿vÏ8* ÙôØĞr&öLúôR}JuÔòØr	fM±ŸOæ<bRù·¬]4:ß‚G±‰,YCR¦šåß'97²hÂBVyq8;&Cøèï@ïÖ˜UPr’’õ¬jŠIòğ…†í+šo¥C´€tÿ7ËŸ ô!‰ñ¶ø„/jîƒĞÈz…u{F™ùå*•²;P@ê£Ç#o>QÁäsğĞn±h"÷?z¦x¯y½gâNn—{‰ËëôNN „=,ÑºŞ‹`¶‰’öğ.İGßsÈ¿Èk¼ÛgâõIü±?t¨ĞÑPòÆa’W„:?5Rİ¼&SCì»ÄœgH@è49fEgà®î`ÔÛÜÂgÄf„yXÑ İ£L¸© G=¿åÜˆ;*‰èGÁÔW¿®–yi<W‰UÒPR‹^!‹6®Z×í}6C'§Ö éì;	œüá¥÷ihjÃëŠ6×cv9 f¤K/J1z$v¥Úf;’À†˜SÚÙz?'¼¤ş^ÑõS- «C®gúŒ²…&N0—·À	àâ©=5qÍm³ıSÂö®8"—š×vr¸šn2wÛM8”BØ_‰˜Á&>e‚3:ım”$ºFw9:£¤Dj†A{¤€X4aqñ°œBó‚À¢±Ú® •m&WWI{èai&¥İ®–ª4ú®ßíp›2/8˜ØeîeÛ,ú:ÌN-Õ¦Ü0lÔÓƒÖîF7[ÅÓÔˆ³üá s?Ñ›x©!ËÈF^MÑñ_!`„€Ğ·nBeÀÿ˜¢ëä)À$+6Hİßç]ˆ•yP™‘×åœîÊ[‡ªŸJ€ë#9©Ü²t¨)ĞåŸdtR0¶#+ÓQdÎ&ÂuÔê¡,¼,aRğ|ŠÅZûĞÑ# #š)fe®:h…wºÎ1²ù+‘PÉâ]s½`MÇYéLDQíwØå:ú Ò¾2g«©¿ö¨Ñ‰w=IÔ8ôÉ3¯—ïxÉyÅT‹Œ‚–:fÑÒ¹tÂÊ]5¡ÛÈuÊRd*`uü’FÔÓ@z„s°©KÕ2Úr®ª¢!:d<Ãï‚9…ÃæÉs‘ú'íİKp‚å—î
Şï2å“
Üä5¿¸×†xouFş9Ù2Ilq ¦PÆ·/¡êumh”Ê±^~.—{>ù˜®ğä‡ìA?*²e2}" À"Â·)§æø5-ÑXÉ8Këƒ1_‰ì<õ6ù_×QS‡O'l–ÿµY/Äj_$›Ê-õKöß_æì¸¯ŞÏ«qEÂqhV {õ¹J²I i#ÔM»ä±w›pš&k’™.m8ÆşJöı
½$üO,é€w“£Âxä…şàxZ“ÃŞniP:—ÿ•K_XJØ9À@kk™}fVÜ¼GÍ¼¨)ÇDêchÜ/ïçÅ_U «‚2€ĞT'ÚÅ«SC#5åtlH5H%ˆk|Ú¤4¡§ÓIPú½DP¶Dù¬FƒåH|£Ö$hÇx¾ên¨fblGÈsL¼O‘:»ßÂwÛÜ:ÒÍX–ú¾ëfme7âä&´)ÂÑfxr½’„9q‰ä6&ªBûm‡ W5ØòJj'»L7åÖ…<²îWaöiÖÜã6¡út1»¬vÃíï…õË´]Ó¼åı6
I×çIÿsºH­áGm•xµ¼Ş‚Ø‰ÿt¹õø³ "Š06ÄÕÙÆı\‹n ä,O¤ •ø–Íªrßô‘c>÷ªôÚÀi¶¿\tN_§‰Cò©C8gz-š+‹
”2àä÷ Ò>ãJG×À„‚p»ùëóµÈY„¬Îş6"á69 µLÇ‘Ì›0ZzÑ¡¼ˆhÂj8úÓ tí•ÅzŒ¾{tvŠƒ%‹Ö™¹`†¤™¦`0¼êèîäÖ´ß¹sÊ~ÕKéíBr@xN£:á,0L’G Ôi+öu ƒÙ­°ÊõË‚s4”öõ¶zØ¢ˆêÍ–¯ãóä¤ç§¶¡Pö	¡€­Ôô5*ô—£Â×ugWpWc½ÖÍjÆ‘}N¯Ç¿w,„õà_ÒÒğÕHÎ~tGÈ’›6Ê#ñó­çzğ#ÁÒ¹}@fc•ÓÄ×U·ÖøYá^;GÙm–Ãs†*«ÕVsØÅM;¦<ï¾¯ro8	OO¥½ãi¹Œ…½ º»`3,e0@±š:•4à/<@.·ƒA‘ƒ bà¥VÛMó]±ãµÄ81Y†
¨cuÍfşEã†ËG¦Y!Í£a~ê…„ÏXWòÎ%ö€;<"û²^” O¬Yqë!üA²–Œªî~O4©Ï¯ñ©Œ]¤òÊÂªP÷lø²Æ?MÊØâËX§J?å5ïö¨êgğ´Hì?6ÿyubZLĞFv-™œ2ævæßêxü¸“]w)GYÎÆø_8ª»?C¢Bp‹O„w<2Ã›6+B,Òõ¥h˜#òı#+z—E£^¹°AŒ+Y—=ëSy•59tlÅg!íİ)/u0ØÿSZ¥B‹Z@½lDc’ÒåCóâZiEùñáÚ¼¥{ØOSìç~á-‰¿ÃP…Ùô[‰·ğtÛ%Z¸ĞqŞQ ÁòÙ¾ òõ˜Ö)nö¦ênÜï°ôÌê›$}ß¦Ç¸Ğ˜æùßÉ9Ë î4E/ÿJPy§jò¥Ôí°1’¯j)B-’>ß¢‚¨sŞ%n¢jJˆ¼Ëi'mŞ÷’ëgÏ;§ºš±÷õõ¾}GzÍ[÷uZs«yô¬¬½¾ö’K{{GiQ¯;¹‚TÜa+Ï;WE·±¾»ñÅ_®a†9¾¢TeÛåÁ•¤Jí/<„jô]ê‡nP½<¹†]!‹GiˆÆ,Çªd{Í“X†›ºTš1ÅûÄ–møÎ¾Ú:“º1xAÕ×R¯[‡,*'éè!˜±3¥şˆa#w/M÷÷{a‹=\N'kˆ0ªåØîíâü´#’{@àêz’¬ğ¢é ÒıÔW*ÛÏ¬Õ‡ÉáÍZºûÉ¶/ÇÖ,‰nŸ(½.óÇE…Í•n´Æf°ÔÁ'Ì\t„CÁ8½ô®ˆ…™ÉrZr=v…Ï5.Ô‡Süˆ&Ï§™b¯¡AîˆT0Šø„<[ü¤\ˆŞiîäÅ¦q$Ï“b!’åàñÉp+g.{´NzŸ™bæN‚	…auYZ°9}ŞWXC*iJ6rÜyEŠ% lôëÿ|Û¬n y#%Ò(=(Hl§VÙ:”Ê#‚¦J†xdîoÁS…_šÖcp›¹»@+î‡,HkmÏKX~Í0@aSíqIÒi0@uÆ‰l¾
†›ÌêçšG')ºlGò±£4KÍğl0ñE½5pšmÛ½:âÇz+M÷ıêá®™ëoZ ë|øX™VÍ¸0`òû“‰ã™n­>©˜£@ÇÓ%„5ç™İ{P˜<}bDÖó•/È=MŠÈl¤ƒ,¡÷ÀdK¤8SeĞ:äc¬1ƒ¿5v©¢GVäŠ/¨‹|]ë©Yû+„Úv„u¬Á€Qé´ËoÄP\3KÈye0r¯:ÎˆÜ(!2ĞˆÊíÂ¸MGCg±Êğ°N4ú&b\³–Ô0Ië®õ®ai‹¹¦á?‹È ·sïÍF--9ˆáš‡C¦CÀŠ"ìôßD=ú£BÖE€²9%´J6œ"+l)¨NWT _¼8%G~â]ô¿7–ç×“uáLtÓİ |m¾[å¥¥Í«*±¾’ÔEWC„Éy±Œµ¹f}N¢Â¨ÇsÑ-D[âa·Ä^æ—ˆ©÷Ìı»yúÓ‚ÏE¹Q'k^ÌÑHö0[Gtá¨N‹)'mİöx[™M—.¬&5qU7b;}Y;ä™¶V¼×ù sƒ9†´l¿jƒàz<GoÛûí´JµäÊ²Í¦MúP!Lı:hGANë­28iİMoê“ Ä Í€Š¥ üöÆbĞEº%—-añ ê…À"”0“BÎZhÑÇğ™”š“e|Àó{ ´½¬Ş)A5ëæàk–ÙFÜx­Fß
¹=Ù¿ŒLşGV·LFæF'¹Â[_i²Íæ<‡| YZTïoVBÆÏ[qÄ4£
WÃP RU‹îáÕ-”@^ ¾rºôt}Š!HL…ì‘r›Œ§Ü@yœÉ< q*ò>¶Ç¶#KU6diÄÍŸ
]ÏÆä ü3ßîéÛ;U.±‹‘…2	Â€ı¼õO¦‘ Â8ˆqVUÁãızmœG1U%{s8èÖÃÍØÈ~\ÒPŠö4ô›²FúÀ²Z½2.\È~Ğ’±§¹§‰µFƒÄuæÜ_¯OËñ5 x_Ú•@2{°‚‹ïÔia›M'C¦1™SºP!Ë çÈÌ@\ßA=èEÕùÊÛ““‰oVi¤&d–€]èÇ1[ü´ù@Y‹78ËRS÷ã,æÜOÈ¹/9—mgÊ*ñ±.–§ò‡æH^™šŒÊh!j-•C¥ÚÓÏGçlá\RÏÚ5èç”Aª»«9{ı
şÚœ	Î]èn(ÚƒŒ½‡•¢ÁØ@Å?Ê±ä|–aóæ;L°•
ëV¼ˆ«9ıh#¦ÑUN‡ì+¢m4JI±¿R+»ş½ 3èÂ’ó	Åëe6w¯~åŸXš÷F“»áe·¿¯š-‘ á¥LH¨ä
‡!.ZI@yŞ&´À‚ˆºtœFĞ/¯•nÛ÷^©™µz—;­¦p©ÚjyØ†“¬å[‘óà€zPÂ¦B˜Îİ°dÁ³C”Ør4"xAŒMÿ†àu©ãÙ@S;|9Û¹;N–šG•+[	!ÎŠ4Œl˜e&¦ŠV9ò¬º1ô¹À|ô\ÈğÔ©.t½ìÛ”}ßjìætŞÓ0‰CÖà×‰|ÆnW{_‰ö”®F5ïó~NûdP5N›/ßöx aØà÷Í8€÷¬ŞxA‚ÃúG‚.ñ¦;‘2ñ¦rÒk«wÄ{—ğËy2FáÊ ?y]ë’Ó¢68-	_Ût²İ¡Mşz&B±yâG=CÚœ¢/m-;`Eó2“—c&,§~
^ouÂNhæs­Š´hO™¡¤7Ú¡Ú/ÕK”é5SœÍx¦HTZ_Onj` +”Ç-ÀOz›İşpºıaùôì·É—QĞ(
Ø§*4œ'İâ<ñ‰ñ®íè÷ñ¾¨^=Ö,ÛG†®©Í9Xo5éxFä‘1«¶BU"lM³…F‘&†n¡7b±uõåu%ŒE)Ğ–µ’¶9EßqàäáÙkœK
ÿÙ§bc{÷š«¸}(¼äEÇ2H	/	·3İZ"¢— ›Íˆ†¯8‘iÄ¶¥İ^$ı80­ß9C:.ôc!ÇÜ]¥¼J ú	â¸	°ÔË_Rodı§¨Œ5aA·­°êlad
¯ÏYV11"7·Úa²g@Snî’ÍÌºeø­fa÷`Î¸05A$¬uŠ'wÁyEÇë™èCÓßË	óO°˜Í6€µ1ì…³ßê¾ˆE¸÷,Öa½À~ôƒşù-îõŸD!ğ+hÆ·ĞE­IËøw=„ÎûËQ…a6¦¸¹b»C0¯õ)ÍNÌ`Öİ¸ÙÌ¥©!3$nu8[ÍôD¡õ…%Ò¢¹peædóÔà<“>ÛÈ™m·±ØhfË­×GÒ·%'¯¯àáAD…™U@ş€ N¤ØJĞ¾á…EON¡¥ÄİšÌ_«Àû€Sê|Vô1;¤˜ØRÓîëex^ÅgŸP@ãK¹–Ot¢9Ï•£|Ê¼8‹“;i›vZ7ß³Á¨„ò/RâíMm¬léiwv37«°ú ÁA…„EZœİJÍ¿¯€áEDA˜‡Qåa^DÅ›Ÿ[AÙ‡Öõb?N¤ÛÚ^ÜÆÉ—´q»%›ßZÀŞ‚Æ—#rÊ,¾ê…D˜Q}æT úÁ„BQ,åé^tÆ;•›~ZÜÉh·r²/®áåE]œÏI¡´Å»˜OS ëÁy†{~]ÎK¤¸Ù’ÕnıdX#ÒËï¸a’Gm“oka{G“Wjó}*ü(
ò<,Šè=s*&ÿÔø&bÔNù¤ÙqÖ$öÚ6Ş¶Ä·›³Y¨Õòı,è(rò,-êî}fU şÀ€_ÂŒZ(ŞñÄ$šÚ^ßÆÃ—ˆr3/«àú@ENA¤„ÙÕ^şÄ˜QKå»]˜ÏQ äÁ[„ØÓ^êÅ}D+šû\ÉW´ğ¸#’Éoµa¿EƒD9›—[qÚ'ŞĞÆâ•N}§Ó*êı|
$<ÛˆÚ2ß®ÀæV÷2S¬èéqt&9×–óv*6ÿ´ºœHA°…¡ÅK»E™WMñ¯$àÙ@Õ‚ş&Ô^øÄ™dW[ğÛ"ØÎĞ¦âÕOı Â+Œú(òD,šé]uÎ?§€Òìh2s­(ïñb'NÑ¤äÚZŞŞÅÇœ“Ji¿uƒ>„:Ÿ[BÙÖ,öê5~¾„YTÖúõ<Kˆº1Ÿ¥@İ‚Ï¡ ÆÃ”‹z:BM®#æÉW´ñ¹%”ßxÂn/gãRHî±e§]ĞÍã¬Hê±}¦Ô-úìjO|¢	Ì5«¼ù‹8w3a«Fù—pr .Áç†Ríun<g‰R7ï³a¨Dñ˜'RÑîçeP\áÉGµ¿cƒI	µ5¾½„%YÜÖÊö¼6‹·9±•¦|×
ó<*Šü<ˆ:3Ÿ«Bù vÀ7²¬éqv$6Ù¶Ö¶÷´1»¥˜İRÍï¯`àAA…‡EfŸU@ı€ !Æ”#xÊ½bO!¡ÄÆ›–[wÚ3ß¨Àò€.çR,ìéhwr2-®îåg_PÀáD›Z@Ü‚Éµ!¾Å„E_œÃK‰º7Ÿ±A¥„ßÁ_†Â|.ä:[ÛEÙœ×Jñ¾%†ŞÅzEG“Oi£wÊ1¿¤€ÛÙÖ&ôÔ8û’n[dÛYØÔÒúìiFu•?‚("òÌ/ªàü¯¯àáAD…™U@ş€ N¤ØJĞ¾á…EON¡¥ÄİšÌ_«Àû€Sê|Vô1;¤˜ØRÓîëex^ÅgŸP@ãK¹–Ot¢9Ï•£|Ê¼8‹“;i›vZ7ß³Á¨„ò/RâíMm¬léiwv37«°ú ÁA…„EZœİJÍ¿¯€áEDA˜‡Qåa^DÅ›Ÿ[AÙ‡Öõb?N¤ÛÚ^ÜÆÉ—´q»%›ßZÀŞ‚Æ—#rÊ,¾ê…D˜Q}æT úÁ„BQ,åé^tÆ;•›~ZÜÉh·r²/®áåE]œÏI¡´Å»˜OS ëÁy†{~]ÎK¤¸Ù’ÕnıdX#ÒËï¸a’Gm“oka{G“Wjó}*ü(
ò<,Šè=s*&ÿÔø&bÔNù¤ÙqÖ$öÚ6Ş¶Ä·›³Y¨Õòı,è(rò,-êî}fU şÀ€_ÂŒZ(ŞñÄ$šÚ^ßÆÃ—ˆr3/«àú@ENA¤„ÙÕ^şÄ˜QKå»]˜ÏQ äÁ[„ØÓ^êÅ}D+šû\ÉW´ğ¸#’Éoµa¿EƒD9›—[qÚ'ŞĞÆâ•N}§Ó*êı|
$<ÛˆÚ2ß®ÀæV÷2S¬èéqt&9×–óv*6ÿ´ºœHA°…¡ÅK»E™WMñ¯$àÙ@Õ‚ş&Ô^øÄ™dW[ğÛ"ØÎĞ¦âÕOı Â+Œú(òD,šé]uÎ?§€Òìh2s­(ïñb'NÑ¤äÚZŞŞÅÇœ“Ji¿uƒ>„:Ÿ[BÙÖ,öê5~¾„YTÖúõ<Kˆº1Ÿ¥@İ‚Ï¡ ÆÃ”‹z:BM®#æÉW´ñ¹%”ßxÂn/gãRHî±e§]ĞÍã¬Hê±}¦Ô-úìjO|¢	Ì5«¼ù‹8w3a«Fù—pr .Áç†Ríun<g‰R7ï³a¨Dñ˜'RÑîçeP\áÉGµ¿cƒI	µ5¾½„%YÜÖÊö¼6‹·9±•¦|×
ó<*Šü<ˆ:3Ÿ«Bù vÀ7²¬éqv$6Ù¶Ö¶÷´1»¥˜İRÍï¯`àAA…‡EfŸU@ı€ !Æ”#xÊ½bO!¡ÄÆ›–[wÚ3ß¨Àò€.çR,ìéhwr2-®îåg_PÀáD›Z@Ü‚Éµ!¾Å„E_œÃK‰º7Ÿ±A¥„ßÁ_†Â|.ä:[ÛEÙœ×Jñ¾%†ŞÅzEG“Oi£wÊ1¿¤€ÛÙÖ&ôÔ8û’n[dÛYØÔÒúìiFu•?‚("òÌ/ªàü¯¯àáAD…™U@ş€ N¤ØJĞ¾á…EON¡¥ÄİšÌ_«Àû€Sê|Vô1;¤˜ØRÓîëex^ÅgŸP@ãK¹–Ot¢9Ï•£|Ê¼8‹“;i›vZ7ß³Á¨„ò/RâíMm¬léiwv37«°ú ÁA…„EZœİJÍ¿¯€áEDA˜‡Qåa^DÅ›Ÿ[AÙ‡Öõb?N¤ÛÚ^ÜÆÉ—´q»%›ßZÀŞ‚Æ—#rÊ,¾ê…D˜Q}æT úÁ„BQ,åé^tÆ;•›~ZÜÉh·r²/®áåE]œÏI¡´Å»˜OS ëÁy†{~]ÎK¤¸Ù’ÕnıdX#ÒËï¸a’Gm“oka{G“Wjó}*ü(
ò<,Šè=s*&ÿÔø&bÔNù¤ÙqÖ$öÚ6Ş¶Ä·›³Y¨Õòı,è(rò,-êî}fU şÀ€_ÂŒZ(ŞñÄ$šÚ^ßÆÃ—ˆr3/«àú@ENA¤„ÙÕ^şÄ˜QKå»]˜ÏQ äÁ[„ØÓ^êÅ}D+šû\ÉW´ğ¸#’Éoµa¿EƒD9›—[qÚ'ŞĞÆâ•N}§Ó*êı|
$<ÛˆÚ2ß®ÀæV÷2S¬èéqt&9×–óv*6ÿ´ºœHA°…¡ÅK»E™WMñ¯$àÙ@Õ‚ş&Ô^øÄ™dW[ğÛ"ØÎĞ¦âÕOı Â+Œú(òD,šé]uÎ?§€Òìh2s­(ïñb'NÑ¤äÚZŞŞÅÇœ“Ji¿uƒ>„:Ÿ[BÙÖ,öê5~¾„YTÖúõ<Kˆº1Ÿ¥@İ‚Ï¡ ÆÃ”‹z:BM®#æÉW´ñ¹%”ßxÂn/gãRHî±e§]ĞÍã¬Hê±}¦Ô-úìjO|¢	Ì5«¼ù‹8w3a«Fù—pr .Áç†Ríun<g‰R7ï³a¨Dñ˜'RÑîçeP\áÉGµ¿cƒI	µ5¾½„%YÜÖÊö¼6‹·9±•¦|×
ó<*Šü<ˆ:3Ÿ«Bù vÀ7²¬éqv$6Ù¶Ö¶÷´1»¥˜İRÍï¯`àAA…‡EfŸU@ı€ !Æ”#xÊ½bO!¡ÄÆ›–[wÚ3ß¨Àò€.çR,ìéhwr2-®îåg_PÀáD›Z@Ü‚Éµ!¾Å„E_œÃK‰º7Ÿ±A¥„ßÁ_†Â|.ä:[ÛEÙœ×Jñ¾%†ŞÅzEG“Oi£wÊ1¿¤€ÛÙÖ&ôÔ8û’n[dÛYØÔÒúìiFu•?‚("òÌ/ªàü¯¯àáAD…™U@ş€ N¤ØJĞ¾á…EON¡¥ÄİšÌ_«Àû€Sê|Vô1;¤˜ØRÓîëex^ÅgŸP@ãK¹–Ot¢9Ï•£|Ê¼8‹“;i›vZ7ß³Á¨„ò/RâíMm¬léiwv37«°ú ÁA…„EZœİJÍ¿¯€áEDA˜‡Qåa^DÅ›Ÿ[AÙ‡Öõb?N¤ÛÚ^ÜÆÉ—´q»%›ßZÀŞ‚Æ—#rÊ,¾ê…D˜Q}æT úÁ„BQ,åé^tÆ;•›~ZÜÉh·r²/®áåE]œÏI¡´Å»˜OS ëÁy†{~]ÎK¤¸Ù’ÕnıdX#ÒËï¸a’Gm“oka{G“Wjó}*ü(
ò<,Šè=s*&ÿÔø&bÔNù¤ÙqÖ$öÚ6Ş¶Ä·›³Y¨Õòı,è(rò,-êî}fU şÀ€_ÂŒZ(ŞñÄ$šÚ^ßÆÃ—ˆr3/«àú@ENA¤„ÙÕ^şÄ˜QKå»]˜ÏQ äÁ[„ØÓ^êÅ}D+šû\ÉW´ğ¸#’Éoµa¿EƒD9›—[qÚ'ŞĞÆâ•N}§Ó*êı|
$<ÛˆÚ2ß®ÀæV÷2S¬èéqt&9×–óv*6ÿ´ºœHA°…¡ÅK»E™WMñ¯$àÙ@Õ‚ş&Ô^øÄ™dW[ğÛ"ØÎĞ¦âÕOı Â+Œú(òD,šé]uÎ?§€Òìh2s­(ïñb'NÑ¤äÚZŞŞÅÇœ“Ji¿uƒ>„:Ÿ[BÙÖ,öê5~¾„YTÖúõ<Kˆº1Ÿ¥@İ‚Ï¡ ÆÃ”‹z:BM®#æÉW´ñ¹%”ßxÂn/gãRHî±e§]ĞÍã¬Hê±}¦Ô-úìjO|¢	Ì5«¼ù‹8w3a«Fù—pr .Áç†Ríun<g‰R7ï³a¨Dñ˜'RÑîçeP\áÉGµ¿cƒI	µ5¾½„%YÜÖÊö¼6‹·9±•¦|×
ó<*Šü<ˆ:3Ÿ«Bù vÀ7²¬éqv$6Ù¶Ö¶÷´1»¥˜İRÍï¯`àAA…‡EfŸU@ı€ !Æ”#xÊ½bO!¡ÄÆ›–[wÚ3ß¨Àò€.çR,ìéhwr2-®îåg_PÀáD›Z@Ü‚Éµ!¾Å„E_œÃK‰º7Ÿ±A¥„ßÁ_†Â|.ä:[ÛEÙœ×Jñ¾%†ŞÅzEG“Oi£wÊ1¿¤€ÛÙÖ&ôÔ8û’n[dÛYØÔÒúìiFu•?‚("òÌ/ªàü¯¯àáAD…™U@ş€ N¤ØJĞ¾á…EON¡¥ÄİšÌ_«Àû€Sê|Vô1;¤˜ØRÓîëex^ÅgŸP@ãK¹–Ot¢9Ï•£|Ê¼8‹“;i›vZ7ß³Á¨„ò/RâíMm¬léiwv37«°ú ÁA…„EZœİJÍ¿¯€áEDA˜‡Qåa^DÅ›Ÿ[AÙ‡Öõb?N¤ÛÚ^ÜÆÉ—´q»%›ßZÀŞ‚Æ—#rÊ,¾ê…D˜Q}æT úÁ„BQ,åé^tÆ;•›~ZÜÉh·r²/®áåE]œÏI¡´Å»˜OS ëÁy†{~]ÎK¤¸Ù’ÕnıdX#ÒËï¸a’Gm“oka{G“Wjó}*ü(
ò<,Šè=s*&ÿÔø&bÔNù¤ÙqÖ$öÚ6Ş¶Ä·›³Y¨Õòı,è(rò,-êî}fU şÀ€_ÂŒZ(ŞñÄ$šÚ^ßÆÃ—ˆr3/«àú@ENA¤„ÙÕ^şÄ˜QKå»]˜ÏQ äÁ[„ØÓ^êÅ}D+šû\ÉW´ğ¸#’Éoµa¿EƒD9›—[qÚ'ŞĞÆâ•N}§Ó*êı|
$<ÛˆÚ2ß®ÀæV÷2S¬èéqt&9×–óv*6ÿ´ºœHA°…¡ÅK»E™WMñ¯$àÙ@Õ‚ş&Ô^øÄ™dW[ğÛ"ØÎĞ¦âÕOı Â+Œú(òD,šé]uÎ?§€Òìh2s­(ïñb'NÑ¤äÚZŞŞÅÇœ“Ji¿uƒ>„:Ÿ[BÙÖ,öê5~¾„YTÖúõ<Kˆº1Ÿ¥@İ‚Ï¡ ÆÃ”‹z:BM®#æÉW´ñ¹%”ßxÂn/gãRHî±e§]ĞÍã¬Hê±}¦Ô-úìjO|¢	Ì5«¼ù‹8w3a«Fù—pr .Áç†Ríun<g‰R7ï³a¨Dñ˜'RÑîçeP\áÉGµ¿cƒI	µ5¾½„%YÜÖÊö¼6‹·9±•¦|×
ó<*Šü<ˆ:3Ÿ«Bù vÀ7²¬éqv$6Ù¶Ö¶÷´1»¥˜İRÍï¯`àAA…‡EfŸU@ı€ !Æ”#xÊ½bO!¡ÄÆ›–[wÚ3ß¨Àò€.çR,ìéhwr2-®îåg_PÀáD›Z@Ü‚Éµ!¾Å„E_œÃK‰º7Ÿ±A¥„ßÁ_†Â|.ä:[ÛEÙœ×Jñ¾%†ŞÅzEG“Oi£wÊ1¿¤€ÛÙÖ&ôÔ8û’n[dÛYØÔÒúìiFu•?‚("òÌ/ªàü¯¯àáAD…™U@ş€ N¤ØJĞ¾á…EON¡¥ÄİšÌ_«Àû€Sê|Vô1;¤˜ØRÓîëex^ÅgŸP@ãK¹–Ot¢9Ï•£|Ê¼8‹“;i›vZ7ß³Á¨„ò/RâíMm¬léiwv37«°ú ÁA…„EZœİJÍ¿¯€áEDA˜‡Qåa^DÅ›Ÿ[AÙ‡Öõb?N¤ÛÚ^ÜÆÉ—´q»%›ßZÀŞ‚Æ—#rÊ,¾ê…D˜Q}æT úÁ„BQ,åé^tÆ;•›~ZÜÉh·r²/®áåE]œÏI¡´Å»˜OS ëÁy†{~]ÎK¤¸Ù’ÕnıdX#ÒËï¸a’Gm“oka{G“Wjó}*ü(
ò<,Šè=s*&ÿÔø&bÔNù¤ÙqÖ$öÚ6Ş¶Ä·›³Y¨Õòı,è(rò,-êî}fU şÀ€_ÂŒZ(ŞñÄ$šÚ^ßÆÃ—ˆr3/«àú@ENA¤„ÙÕ^şÄ˜QKå»]˜ÏQ äÁ[„ØÓ^êÅ}D+šû\ÉW´ğ¸#’Éoµa¿EƒD9›—[qÚ'ŞĞÆâ•N}§Ó*êı|
$<ÛˆÚ2ß®ÀæV÷2S¬èéqt&9×–óv*6ÿ´ºœHA°…¡ÅK»E™WMñ¯$àÙ@Õ‚ş&Ô^øÄ™dW[ğÛ"ØÎĞ¦âÕOı Â+Œú(òD,šé]uÎ?§€Òìh2s­(ïñb'NÑ¤äÚZŞŞÅÇœ“Ji¿uƒ>„:Ÿ[BÙÖ,öê5~¾„YTÖúõ<Kˆº1Ÿ¥@İ‚Ï¡ ÆÃ”‹z:BM®#æÉW´ñ¹%”ßxÂn/gãRHî±e§]ĞÍã¬Hê±}¦Ô-úìjO|¢	Ì5«¼ù‹8w3a«Fù—pr .Áç†Ríun<g‰R7ï³a¨Dñ˜'RÑîçeP\áÉGµ¿cƒI	µ5¾½„%YÜÖÊö¼6‹·9±•¦|×
ó<*Šü<ˆ:3Ÿ«Bù vÀ7²¬éqv$6Ù¶Ö¶÷´1»¥˜İRÍï¯`àAA…‡EfŸU@ı€ !Æ”#xÊ½bO!¡ÄÆ›–[wÚ3ß¨Àò€.çR,ìéhwr2-®îåg_PÀáD›Z@Ü‚Éµ!¾Å„E_œÃK‰º7Ÿ±A¥„ßÁ_†Â|.ä:[ÛEÙœ×Jñ¾%†ŞÅzEG“Oi£wÊ1¿¤€ÛÙÖ&ôÔ8û’n[dÛYØÔÒúìiFu•?‚("òÌ/ªàü¯¯àáAD…™U@ş€ N¤ØJĞ¾á…EON¡¥ÄİšÌ_«Àû€Sê|Vô1;¤˜ØRÓîëex^ÅgŸP@ãK¹–Ot¢9Ï•£|Ê¼8‹“;i›vZ7ß³Á¨„ò/RâíMm¬léiwv37«°ú ÁA…„EZœİJÍ¿¯€áEDA˜‡Qåa^DÅ›Ÿ[AÙ‡Öõb?N¤ÛÚ^ÜÆÉ—´q»%›ßZÀŞ‚Æ—#rÊ,¾ê…D˜Q}æT úÁ„BQ,åé^tÆ;•›~ZÜÉh·r²/®áåE]œÏI¡´Å»˜OS ëÁy†{~]ÎK¤¸Ù’ÕnıdX#ÒËï¸a’Gm“oka{G“Wjó}*ü(
ò<,Šè=s*&ÿÔø&bÔNù¤ÙqÖ$öÚ6Ş¶Ä·›³Y¨Õòı,è(rò,-êî}fU şÀ€_ÂŒZ(ŞñÄ$šÚ^ßÆÃ—ˆr3/«àú@ENA¤„ÙÕ^şÄ˜QKå»]˜ÏQ äÁ[„ØÓ^êÅ}D+šû\ÉW´ğ¸#’Éoµa¿EƒD9›—[qÚ'ŞĞÆâ•N}§Ó*êı|
$<ÛˆÚ2ß®ÀæV÷2S¬èéqt&9×–óv*6ÿ´ºœHA°…¡ÅK»E™WMñ¯$àÙ@Õ‚ş&Ô^øÄ™dW[ğÛ"ØÎĞ¦âÕOı Â+Œú(òD,šé]uÎ?§€Òìh2s­(ïñb'NÑ¤äÚZŞŞÅÇœ“Ji¿uƒ>„:Ÿ[BÙÖ,öê5~¾„YTÖúõ<Kˆº1Ÿ¥@İ‚Ï¡ ÆÃ”‹z:BM®#æÉW´ñ¹%”ßxÂn/gãRHî±e§]ĞÍã¬Hê±}¦Ô-úìjO|¢	Ì5«¼ù‹8w3a«Fù—pr .Áç†Ríun<g‰R7ï³a¨Dñ˜'RÑîçeP\áÉGµ¿cƒI	µ5¾½„%YÜÖÊö¼6‹·9±•¦|×
ó<*Šü<ˆ:3Ÿ«Bù vÀ7²¬éqv$6Ù¶Ö¶÷´1»¥˜İRÍï¯`àAA…‡EfŸU@ı€ !Æ”#xÊ½bO!¡ÄÆ›–[wÚ3ß¨Àò€.çR,ìéhwr2-®îåg_PÀáD›Z@Ü‚Éµ!¾Å„E_œÃK‰º7Ÿ±A¥„ßÁ_†Â|.ä:[ÛEÙœ×Jñ¾%†ŞÅzEG“Oi£wÊ1¿¤€ÛÙÖ&ôÔ8û’n[dÛYØÔÒúìiFu•?‚("òÌ/ªàü¯¯àáAD…™U@ş€ N¤ØJĞ¾á…EON¡¥ÄİšÌ_«Àû€Sê|Vô1;¤˜ØRÓîëex^ÅgŸP@ãK¹–Ot¢9Ï•£|Ê¼8‹“;i›vZ7ß³Á¨„ò/RâíMm¬léiwv37«°ú ÁA…„EZœİJÍ¿¯€áEDA˜‡Qåa^DÅ›Ÿ[AÙ‡Öõb?N¤ÛÚ^ÜÆÉ—´q»%›ßZÀŞ‚Æ—#rÊ,¾ê…D˜Q}æT úÁ„BQ,åé^tÆ;•›~ZÜÉh·r²/®áåE]œÏI¡´Å»˜OS ëÁy†{~]ÎK¤¸Ù’ÕnıdX#ÒËï¸a’Gm“oka{G“Wjó}*ü(
ò<,Šè=s*&ÿÔø&bÔNù¤ÙqÖ$öÚ6Ş¶Ä·›³Y¨Õòı,è(rò,-êî}fU şÀ€_ÂŒZ(ŞñÄ$šÚ^ßÆÃ—ˆr3/«àú@ENA¤„ÙÕ^şÄ˜QKå»]˜ÏQ äÁ[„ØÓ^êÅ}D+šû\ÉW´ğ¸#’Éoµa¿EƒD9›—[qÚ'ŞĞÆâ•N}§Ó*êı|
$<ÛˆÚ2ß®ÀæV÷2S¬èéqt&9×–óv*6ÿ´ºœHA°…¡ÅK»E™WMñ¯$àÙ@Õ‚ş&Ô^øÄ™dW[ğÛ"ØÎĞ¦âÕOı Â+Œú(òD,šé]uÎ?§€Òìh2s­(ïñb'NÑ¤äÚZŞŞÅÇœ“Ji¿uƒ>„:Ÿ[BÙÖ,öê5~¾„YTÖúõ<Kˆº1Ÿ¥@İ‚Ï¡ ÆÃ”‹z:BM®#æÉW´ñ¹%”ßxÂn/gãRHî±e§]ĞÍã¬Hê±}¦Ô-úìjO|¢	Ì5«¼ù‹8w3a«Fù—pr .Áç†Ríun<g‰R7ï³a¨Dñ˜'RÑîçeP\áÉGµ¿cƒI	µ5¾½„%YÜÖÊö¼6‹·9±•¦|×
ó<*Šü<ˆ:3Ÿ«Bù vÀ7²¬éqv$6Ù¶Ö¶÷´1»¥˜İRÍï¯`àAA…‡EfŸU@ı€ !Æ”#xÊ½bO!¡ÄÆ›–[wÚ3ß¨Àò€.çR,ìéhwr2-®îåg_PÀáD›Z@Ü‚Éµ!¾Å„E_œÃK‰º7Ÿ±A¥„ßÁ_†Â|.ä:[ÛEÙœ×Jñ¾%†ŞÅzEG“Oi£wÊ1¿¤€ÛÙÖ&ôÔ8û’n[dÛYØÔÒúìiFu•?‚("òÌ/ªàü¯¯àáAD…™U@ş€ N¤ØJĞ¾á…EON¡¥ÄİšÌ_«Àû€Sê|Vô1;¤˜ØRÓîëex^ÅgŸP@ãK¹–Ot¢9Ï•£|Ê¼8‹“;i›vZ7ß³Á¨„ò/RâíMm¬léiwv37«°ú ÁA…„EZœİJÍ¿¯€áEDA˜‡Qåa^DÅ›Ÿ[AÙ‡Öõb?N¤ÛÚ^ÜÆÉ—´q»%›ßZÀŞ‚Æ—#rÊ,¾ê…D˜Q}æT úÁ„BQ,åé^tÆ;•›~ZÜÉh·r²/®áåE]œÏI¡´Å»˜OS ëÁy†{~]ÎK¤¸Ù’ÕnıdX#ÒËï¸a’Gm“oka{G“Wjó}*ü(
ò<,Šè=s*&ÿÔø&bÔNù¤ÙqÖ$öÚ6Ş¶Ä·›³Y¨Õòı,è(rò,-êî}fU şÀ€_ÂŒZ(ŞñÄ$šÚ^ßÆÃ—ˆr3/«àú@ENA¤„ÙÕ^şÄ˜QKå»]˜ÏQ äÁ[„ØÓ^êÅ}D+šû\ÉW´ğ¸#’Éoµa¿EƒD9›—[qÚ'ŞĞÆâ•N}§Ó*êı|
$<ÛˆÚ2ß®ÀæV÷2S¬èéqt&9×–óv*6ÿ´ºœHA°…¡ÅK»E™WMñ¯$àÙ@Õ‚ş&Ô^øÄ™dW[ğÛ"ØÎĞ¦âÕOı Â+Œú(òD,šé]uÎ?§€Òìh2s­(ïñb'NÑ¤äÚZŞŞÅÇœ“Ji¿uƒ>„:Ÿ[BÙÖ,öê5~¾„YTÖúõ<Kˆº1Ÿ¥@İ‚Ï¡ ÆÃ”‹z:BM®#æÉW´ñ¹%”ßxÂn/gãRHî±e§]ĞÍã¬Hê±}¦Ô-úìjO|¢	Ì5«¼ù‹8w3a«Fù—pr .Áç†Ríun<g‰R7ï³a¨Dñ˜'RÑîçeP\áÉGµ¿cƒI	µ5¾½„%YÜÖÊö¼6‹·9±•¦|×
ó<*Šü<ˆ:3Ÿ«Bù vÀ7²¬éqv$6Ù¶Ö¶÷´1»¥˜İRÍï¯`àAA…‡EfŸU@ı€ !Æ”#xÊ½bO!¡ÄÆ›–[wÚ3ß¨Àò€.çR,ìéhwr2-®îåg_PÀáD›Z@Ü‚Éµ!¾Å„E_œÃK‰º7Ÿ±A¥„ßÁ_†Â|.ä:[ÛEÙœ×Jñ¾%†ŞÅzEG“Oi£wÊ1¿¤€ÛÙÖ&ôÔ8û’n[dÛYØÔÒúìiFu•?‚("òÌ/ªàü¯¯àáAD…™U@ş€ N¤ØJĞ¾á…EON¡¥ÄİšÌ_«Àû€Sê|Vô1;¤˜ØRÓîëex^ÅgŸP@ãK¹–Ot¢9Ï•£|Ê¼8‹“;i›vZ7ß³Á¨„ò/RâíMm¬léiwv37«°ú ÁA…„EZœİJÍ¿¯€áEDA˜‡Qåa^DÅ›Ÿ[AÙ‡Öõb?N¤ÛÚ^ÜÆÉ—´q»%›ßZÀŞ‚Æ—#rÊ,¾ê…D˜Q}æT úÁ„BQ,åé^tÆ;•›~ZÜÉh·r²/®áåE]œÏI¡´Å»˜OS ëÁy†{~]ÎK¤¸Ù’ÕnıdX#ÒËï¸a’Gm“oka{G“Wjó}*ü(
ò<,Šè=s*&ÿÔø&bÔNù¤ÙqÖ$öÚ6Ş¶Ä·›³Y¨Õòı,è(rò,-êî}fU şÀ€_ÂŒZ(ŞñÄ$šÚ^ßÆÃ—ˆr3/«àú@ENA¤„ÙÕ^şÄ˜QKå»]˜ÏQ äÁ[„ØÓ^êÅ}D+šû\ÉW´ğ¸#’Éoµa¿EƒD9›—[qÚ'ŞĞÆâ•N}§Ó*êı|
$<ÛˆÚ2ß®ÀæV÷2S¬èéqt&9×–óv*6ÿ´ºœHA°…¡ÅK»E™WMñ¯$àÙ@Õ‚ş&Ô^øÄ™dW[ğÛ"ØÎĞ¦âÕOı Â+Œú(òD,šé]uÎ?§€Òìh2s­(ïñb'NÑ¤äÚZŞŞÅÇœ“Ji¿uƒ>„:Ÿ[BÙÖ,öê5~¾„YTÖúõ<Kˆº1Ÿ¥@İ‚Ï¡ ÆÃ”‹z:BM®#æÉW´ñ¹%”ßxÂn/gãRHî±e§]ĞÍã¬Hê±}¦Ô-úìjO|¢	Ì5«¼ù‹8w3a«Fù—pr .Áç†Ríun<g‰R7ï³a¨Dñ˜'RÑîçeP\áÉGµ¿cƒI	µ5¾½„%YÜÖÊö¼6‹·9±•¦|×
ó<*Šü<ˆ:3Ÿ«Bù vÀ7²¬éqv$6Ù¶Ö¶÷´1»¥˜İRÍï¯`àAA…‡EfŸU@ı€ !Æ”#xÊ½bO!¡ÄÆ›–[wÚ3ß¨Àò€.çR,ìéhwr2-®îåg_PÀáD›Z@Ü‚Éµ!¾Å„E_œÃK‰º7Ÿ±A¥„ßÁ_†Â|.ä:[ÛEÙœ×Jñ¾%†ŞÅzEG“Oi£wÊ1¿¤€ÛÙÖ&ôÔ8û’n[dÛYØÔÒúìiFu•?‚("òÌ/ªàü¯¯àáAD…™U@ş€ N¤ØJĞ¾á…EON¡¥ÄİšÌ_«Àû€Sê|Vô1;¤˜ØRÓîëex^ÅgŸP@ãK¹–Ot¢9Ï•£|Ê¼8‹“;i›vZ7ß³Á¨„ò/RâíMm¬léiwv37«°ú ÁA…„EZœİJÍ¿¯€áEDA˜‡Qåa^DÅ›Ÿ[AÙ‡Öõb?N¤ÛÚ^ÜÆÉ—´q»%›ßZÀŞ‚Æ—#rÊ,¾ê…D˜Q}æT úÁ„BQ,åé^tÆ;•›~ZÜÉh·r²/®áåE]œÏI¡´Å»˜OS ëÁy†{~]ÎK¤¸Ù’ÕnıdX#ÒËï¸a’Gm“oka{G“Wjó}*ü(
ò<,Šè=s*&ÿÔø&bÔNù¤ÙqÖ$öÚ6Ş¶Ä·›³Y¨Õòı,è(rò,-êî}fU şÀ€_ÂŒZ(ŞñÄ$šÚ^ßÆÃ—ˆr3/«àú@ENA¤„ÙÕ^şÄ˜QKå»]˜ÏQ äÁ[„ØÓ^êÅ}D+šû\ÉW´ğ¸#’Éoµa¿EƒD9›—[qÚ'ŞĞÆâ•N}§Ó*êı|
$<ÛˆÚ2ß®ÀæV÷2S¬èéqt&9×–óv*6ÿ´ºœHA°…¡ÅK»E™WMñ¯$àÙ@Õ‚ş&Ô^øÄ™dW[ğÛ"ØÎĞ¦âÕOı Â+Œú(òD,šé]uÎ?§€Òìh2s­(ïñb'NÑ¤äÚZŞŞÅÇœ“Ji¿uƒ>„:Ÿ[BÙÖ,öê5~¾„YTÖúõ<Kˆº1Ÿ¥@İ‚Ï¡ ÆÃ”‹z:BM®#æÉW´ñ¹%”ßxÂn/gãRHî±e§]ĞÍã¬Hê±}¦Ô-úìjO|¢	Ì5«¼ù‹8w3a«Fù—pr .Áç†Ríun<g‰R7ï³a¨Dñ˜'RÑîçeP\áÉGµ¿cƒI	µ5¾½„%YÜÖÊö¼6‹·9±•¦|×
ó<*Šü<ˆ:3Ÿ«Bù vÀ7²¬éqv$6Ù¶Ö¶÷´1»¥˜İRÍï¯`àAA…‡EfŸU@ı€ !Æ”#xÊ½bO!¡ÄÆ›–[wÚ3ß¨Àò€.çR,ìéhwr2-®îåg_PÀáD›Z@Ü‚Éµ!¾Å„E_œÃK‰º7Ÿ±A¥„ßÁ_†Â|.ä:[ÛEÙœ×Jñ¾%†ŞÅzEG“Oi£wÊ1¿¤€ÛÙÖ&ôÔ8û’n[dÛYØÔÒúìiFu•?‚("òÌ/ªàü¯¯àáAD…™U@ş€ N¤ØJĞ¾á…EON¡¥ÄİšÌ_«Àû€Sê|Vô1;¤˜ØRÓîëex^ÅgŸP@ãK¹–Ot¢9Ï•£|Ê¼8‹“;i›vZ7ß³Á¨„ò/RâíMm¬léiwv37«°ú ÁA…„EZœİJÍ¿¯€áEDA˜‡Qåa^DÅ›Ÿ[AÙ‡Öõb?N¤ÛÚ^ÜÆÉ—´q»%›ßZÀŞ‚Æ—#rÊ,¾ê…D˜Q}æT úÁ„BQ,åé^tÆ;•›~ZÜÉh·r²/®áåE]œÏI¡´Å»˜OS ëÁy†{~]ÎK¤¸Ù’ÕnıdX#ÒËï¸a’Gm“oka{G“Wjó}*ü(
ò<,Šè=s*&ÿÔø&bÔNù¤ÙqÖ$öÚ6Ş¶Ä·›³Y¨Õòı,è(rò,-êî}fU şÀ€_ÂŒZ(ŞñÄ$šÚ^ßÆÃ—ˆr3/«àú@ENA¤„ÙÕ^şÄ˜QKå»]˜ÏQ äÁ[„ØÓ^êÅ}D+šû\ÉW´ğ¸#’Éoµa¿EƒD9›—[qÚ'ŞĞÆâ•N}§Ó*êı|
$<ÛˆÚ2ß®ÀæV÷2S¬èéqt&9×–óv*6ÿ´ºœHA°…¡ÅK»E™WMñ¯$àÙ@Õ‚ş&Ô^øÄ™dW[ğÛ"ØÎĞ¦âÕOı Â+Œú(òD,šé]uÎ?§€Òìh2s­(ïñb'NÑ¤äÚZŞŞÅÇœ“Ji¿uƒ>„:Ÿ[BÙÖ,öê5~¾„YTÖúõ<Kˆº1Ÿ¥@İ‚Ï¡ ÆÃ”‹z:BM®#æÉW´ñ¹%”ßxÂn/gãRHî±e§]ĞÍã¬Hê±}¦Ô-úìjO|¢	Ì5«¼ù‹8w3a«Fù—pr .Áç†Ríun<g‰R7ï³a¨Dñ˜'RÑîçeP\áÉGµ¿cƒI	µ5¾½„%YÜÖÊö¼6‹·9±•¦|×
ó<*Šü<ˆ:3Ÿ«Bù vÀ7²¬éqv$6Ù¶Ö¶÷´1»¥˜İRÍï¯`àAA…‡EfŸU@ı€ !Æ”#xÊ½bO!¡ÄÆ›–[wÚ3ß¨Àò€.çR,ìéhwr2-®îåg_PÀáD›Z@Ü‚Éµ!¾Å„E_œÃK‰º7Ÿ±A¥„ßÁ_†Â|.ä:[ÛEÙœ×Jñ¾%†ŞÅzEG“Oi£wÊ1¿¤€ÛÙÖ&ôÔ8û’n[dÛYØÔÒúìiFu•?‚("òÌ/ªàü¯¯àáAD…™U@ş€ N¤ØJĞ¾á…EON¡¥ÄİšÌ_«Àû€Sê|Vô1;¤˜ØRÓîëex^ÅgŸP@ãK¹–Ot¢9Ï•£|Ê¼8‹“;i›vZ7ß³Á¨„ò/RâíMm¬léiwv37«°ú ÁA…„EZœİJÍ¿¯€áEDA˜‡Qåa^DÅ›Ÿ[AÙ‡Öõb?N¤ÛÚ^ÜÆÉ—´q»%›ßZÀŞ‚Æ—#rÊ,¾ê…D˜Q}æT úÁ„BQ,åé^tÆ;•›~ZÜÉh·r²/®áåE]œÏI¡´Å»˜OS ëÁy†{~]ÎK¤¸Ù’ÕnıdX#ÒËï¸a’Gm“oka{G“Wjó}*ü(
ò<,Šè=s*&ÿÔø&bÔNù¤ÙqÖ$öÚ6Ş¶Ä·›³Y¨Õòı,è(rò,-êî}fU şÀ€_ÂŒZ(ŞñÄ$šÚ^ßÆÃ—ˆr3/«àú@ENA¤„ÙÕ^şÄ˜QKå»]˜ÏQ äÁ[„ØÓ^êÅ}D+šû\ÉW´ğ¸#’Éoµa¿EƒD9›—[qÚ'ŞĞÆâ•N}§Ó*êı|
$<ÛˆÚ2ß®ÀæV÷2S¬èéqt&9×–óv*6ÿ´ºœHA°…¡ÅK»E™WMñ¯$àÙ@Õ‚ş&Ô^øÄ™dW[ğÛ"ØÎĞ¦âÕOı Â+Œú(òD,šé]uÎ?§€Òìh2s­(ïñb'NÑ¤äÚZŞŞÅÇœ“Ji¿uƒ>„:Ÿ[BÙÖ,öê5~¾„YTÖúõ<Kˆº1Ÿ¥@İ‚Ï¡ ÆÃ”‹z:BM®#æÉW´ñ¹%”ßxÂn/gãRHî±e§]ĞÍã¬Hê±}¦Ô-úìjO|¢	Ì5«¼ù‹8w3a«Fù—pr .Áç†Ríun<g‰R7ï³a¨Dñ˜'RÑîçeP\áÉGµ¿cƒI	µ5¾½„%YÜÖÊö¼6‹·9±•¦|×
ó<*Šü<ˆ:3Ÿ«Bù vÀ7²¬éqv$6Ù¶Ö¶÷´1»¥˜İRÍï¯`àAA…‡EfŸU@ı€ !Æ”#xÊ½bO!¡ÄÆ›–[wÚ3ß¨Àò€.çR,ìéhwr2-®îåg_PÀáD›Z@Ü‚Éµ!¾Å„E_œÃK‰º7Ÿ±A¥„ßÁ_†Â|.ä:[ÛEÙœ×Jñ¾%†ŞÅzEG“Oi£wÊ1¿¤€ÛÙÖ&ôÔ8û’n[dÛYØÔÒúìiFu•?‚("òÌ/ªàü¯¯àáAD…™U@ş€ N¤ØJĞ¾á…EON¡¥ÄİšÌ_«Àû€Sê|Vô1;¤˜ØRÓîëex^ÅgŸP@ãK¹–Ot¢9Ï•£|Ê¼8‹“;i›vZ7ß³Á¨„ò/RâíMm¬léiwv37«°ú ÁA…„EZœİJÍ¿¯€áEDA˜‡Qåa^DÅ›Ÿ[AÙ‡Öõb?N¤ÛÚ^ÜÆÉ—´q»%›ßZÀŞ‚Æ—#rÊ,¾ê…D˜Q}æT úÁ„BQ,åé^tÆ;•›~ZÜÉh·r²/®áåE]œÏI¡´Å»˜OS ëÁy†{~]ÎK¤¸Ù’ÕnıdX#ÒËï¸a’Gm“oka{G“Wjó}*ü(
ò<,Šè=s*&ÿÔø&bÔNù¤ÙqÖ$öÚ6Ş¶Ä·›³Y¨Õòı,è(rò,-êî}fU şÀ€_ÂŒZ(ŞñÄ$šÚ^ßÆÃ—ˆr3/«àú@ENA¤„ÙÕ^şÄ˜QKå»]˜ÏQ äÁ[„ØÓ^êÅ}D+šû\ÉW´ğ¸#’Éoµa¿EƒD9›—[qÚ'ŞĞÆâ•N}§Ó*êı|
$<ÛˆÚ2ß®ÀæV÷2S¬èéqt&9×–óv*6ÿ´ºœHA°…¡ÅK»E™WMñ¯$àÙ@Õ‚ş&Ô^øÄ™dW[ğÛ"ØÎĞ¦âÕOı Â+Œú(òD,šé]uÎ?§€Òìh2s­(ïñb'NÑ¤äÚZŞŞÅÇœ“Ji¿uƒ>„:Ÿ[BÙÖ,öê5~¾„YTÖúõ<Kˆº1Ÿ¥@İ‚Ï¡ ÆÃ”‹z:BM®#æÉW´ñ¹%”ßxÂn/gãRHî±e§]ĞÍã¬Hê±}¦Ô-úìjO|¢	Ì5«¼ù‹8w3a«Fù—pr .Áç†Ríun<g‰R7ï³a¨Dñ˜'RÑîçeP\áÉGµ¿cƒI	µ5¾½„%YÜÖÊö¼6‹·9±•¦|×
ó<*Šü<ˆ:3Ÿ«Bù vÀ7²¬éqv$6Ù¶Ö¶÷´1»¥˜İRÍï¯`àAA…‡EfŸU@ı€ !Æ”#xÊ½bO!¡ÄÆ›–[wÚ3ß¨Àò€.çR,ìéhwr2-®îåg_PÀáD›Z@Ü‚Éµ!¾Å„E_œÃK‰º7Ÿ±A¥„ßÁ_†Â|.ä:[ÛEÙœ×Jñ¾%†ŞÅzEG“Oi£wÊ1¿¤€ÛÙÖ&ôÔ8û’n[dÛYØÔÒúìiFu•?‚("òÌ/ªàü¯¯àáAD…™U@ş€ N¤ØJĞ¾á…EON¡¥ÄİšÌ_«Àû€Sê|Vô1;¤˜ØRÓîëex^ÅgŸP@ãK¹–Ot¢9Ï•£|Ê¼8‹“;i›vZ7ß³Á¨„ò/RâíMm¬léiwv37«°ú ÁA…„EZœİJÍ¿¯€áEDA˜‡Qåa^DÅ›Ÿ[AÙ‡Öõb?N¤ÛÚ^ÜÆÉ—´q»%›ßZÀŞ‚Æ—#rÊ,¾ê…D˜Q}æT úÁ„BQ,åé^tÆ;•›~ZÜÉh·r²/®áåE]œÏI¡´Å»˜OS ëÁy†{~]ÎK¤¸Ù’ÕnıdX#ÒËï¸a’Gm“oka{G“Wjó}*ü(
ò<,Šè=s*&ÿÔø&bÔNù¤ÙqÖ$öÚ6Ş¶Ä·›³Y¨Õòı,è(rò,-êî}fU şÀ€_ÂŒZ(ŞñÄ$šÚ^ßÆÃ—ˆr3/«àú@ENA¤„ÙÕ^şÄ˜QKå»]˜ÏQ äÁ[„ØÓ^êÅ}D+šû\ÉW´ğ¸#’Éoµa¿EƒD9›—[qÚ'ŞĞÆâ•N}§Ó*êı|
$<ÛˆÚ2ß®ÀæV÷2S¬èéqt&9×–óv*6ÿ´ºœHA°…¡ÅK»E™WMñ¯$àÙ@Õ‚ş&Ô^øÄ™dW[ğÛ"ØÎĞ¦âÕOı Â+Œú(òD,šé]uÎ?§€Òìh2s­(ïñb'NÑ¤äÚZŞŞÅÇœ“Ji¿uƒ>„:Ÿ[BÙÖ,öê5~¾„YTÖúõ<Kˆº1Ÿ¥@İ‚Ï¡ ÆÃ”‹z:BM®#æÉW´ñ¹%”ßxÂn/gãRHî±e§]ĞÍã¬Hê±}¦Ô-úìjO|¢	Ì5«¼ù‹8w3a«Fù—pr .Áç†Ríun<g‰R7ï³a¨Dñ˜'RÑîçeP\áÉGµ¿cƒI	µ5¾½„%YÜÖÊö¼6‹·9±•¦|×
ó<*Šü<ˆ:3Ÿ«Bù vÀ7²¬éqv$6Ù¶Ö¶÷´1»¥˜İRÍï¯`àAA…‡EfŸU@ı€ !Æ”#xÊ½bO!¡ÄÆ›–[wÚ3ß¨Àò€.çR,ìéhwr2-®îåg_PÀáD›Z@Ü‚Éµ!¾Å„E_œÃK‰º7Ÿ±A¥„ßÁ_†Â|.ä:[ÛEÙœ×Jñ¾%†ŞÅzEG“Oi£wÊ1¿¤€ÛÙÖ&ôÔ8û’n[dÛYØÔÒúìiFu•?‚("òÌ/ªàü¯¯àáAD…™U@ş€ N¤ØJĞ¾á…EON¡¥ÄİšÌ_«Àû€Sê|Vô1;¤˜ØRÓîëex^ÅgŸP@ãK¹–Ot¢9Ï•£|Ê¼8‹“;i›vZ7ß³Á¨„ò/RâíMm¬léiwv37«°ú ÁA…„EZœİJÍ¿¯€áEDA˜‡Qåa^DÅ›Ÿ[AÙ‡Öõb?N¤ÛÚ^ÜÆÉ—´q»%›ßZÀŞ‚Æ—#rÊ,¾ê…D˜Q}æT úÁ„BQ,åé^tÆ;•›~ZÜÉh·r²/®áåE]œÏI¡´Å»˜OS ëÁy†{~]ÎK¤¸Ù’ÕnıdX#ÒËï¸a’Gm“oka{G“Wjó}*ü(
ò<,Šè=s*&ÿÔø&bÔNù¤ÙqÖ$öÚ6Ş¶Ä·›³Y¨Õòı,è(rò,-êî}fU şÀ€_ÂŒZ(ŞñÄ$šÚ^ßÆÃ—ˆr3/«àú@ENA¤„ÙÕ^şÄ˜QKå»]˜ÏQ äÁ[„ØÓ^êÅ}D+šû\ÉW´ğ¸#’Éoµa¿EƒD9›—[qÚ'ŞĞÆâ•N}§Ó*êı|
$<ÛˆÚ2ß®ÀæV÷2S¬èéqt&9×–óv*6ÿ´ºœHA°…¡ÅK»E™WMñ¯$àÙ@Õ‚ş&Ô^øÄ™dW[ğÛ"ØÎĞ¦âÕOı Â+Œú(òD,šé]uÎ?§€Òìh2s­(ïñb'NÑ¤äÚZŞŞÅÇœ“Ji¿uƒ>„:Ÿ[BÙÖ,öê5~¾„YTÖúõ<Kˆº1Ÿ¥@İ‚Ï¡ ÆÃ”‹z:BM®#æÉW´ñ¹%”ßxÂn/gãRHî±e§]ĞÍã¬Hê±}¦Ô-úìjO|¢	Ì5«¼ù‹8w3a«Fù—pr .Áç†Ríun<g‰R7ï³a¨Dñ˜'RÑîçeP\áÉGµ¿cƒI	µ5¾½„%YÜÖÊö¼6‹·9±•¦|×
ó<*Šü<ˆ:3Ÿ«Bù vÀ7²¬éqv$6Ù¶Ö¶÷´1»¥˜İRÍï¯`àAA…‡EfŸU@ı€ !Æ”#xÊ½bO!¡ÄÆ›–[wÚ3ß¨Àò€.çR,ìéhwr2-®îåg_PÀáD›Z@Ü‚Éµ!¾Å„E_œÃK‰º7Ÿ±A¥„ßÁ_†Â|.ä:[ÛEÙœ×Jñ¾%†ŞÅzEG“Oi£wÊ1¿¤€ÛÙÖ&ôÔ8û’n[dÛYØÔÒúìiFu•?‚("òÌ/ªàü¸aME¯œãIIµ·½±¥,İêÎ¦ Õş(ñP$âÙLÕªüş0¡xÆ•hs+ú$ÙHÕ²ı®æ)Tôø8‘lgkS{ê}XÑ*æıTú(ñH%²İ¬Ìê©~ö4¹`—Cq‰&7×²ñ®$æÙTÔúøFe”_yÂp.#æÊW¾ñ…&ÕHı²®,äéXtÒ:ínOg£SÈé±t¦;×™óT(úğ!JÅ¼ŠN?§ƒÒ	ì4kºyOq¢$ÍÛ®ØæÑVäöX6Óµé¼uŠ>=‡'nÒfíUoÿcH	°5 ¼À‹ƒ:	œ6K·¹³•©|õ?3‚ªü+
ø<‰`7C±Š¦?×ò,é\tÊ;½™V'öÓ6èµp¾#†Éµq¾%…ŞÅF–Ow¢3Ï© ôÀ;ƒ˜S8ê‘|fT;û›XXĞÒáíDmšo]`ÏC£ˆË3¹©–÷w20¯ àÃCˆŠ1?¥€ŞÇ’#lËh»rš/^áÅGOc£KÉ¹µ”¿{‚U,şèp!]ÄÎ›¦X×Òóì(jò|-
ï=bL!«Äú˜QGå“_hÃqŠ$>Û†ÚßvÂ7².®çåQ\äÉY´ÔºûœIU´ÿ¸`AO…£ÉK¶¹µ•½}/&âÕLıªş(ğ!RÄì™jWò,è0s¢(Íó®(æñT$úØÑJå¾]†Î¥|ŞÄ8›’[oÛcÛHÙ²Õ®üæ	V4ô¸8““ki{w3_ªÀı€ +ú)Hõ°=¢ŒÌ+«øúaDE™ŸW@ñ€'Ñæ%TÜøÈ±n§gÓQèäqZ$İÚÎß¦ÀÖ‚ö7+²ù¬êy|	t6;µ™¾U‡şhpB Á'…ÒíFm–oub?Oƒ¢Ì9«”û{]PÌá©Dõ›?X€ĞãJ-¼íˆn2g­PïácGH‘±e¥\ßÊÃ¿ˆ‚3© öÀ4ƒº	Ÿ7B±Œ¦+Öùô9z–uK=»š/_àÂCŠ%>İ†Î§pÒ"íÍn¯fãWHğ°!¢ÅÏ£LÉ«´ø¸‘iguR?ïƒbL1«§øÑämXlÑjç}Së)zö5J½¼‹.9ç–Svê5¼‰6´q¸%‘ßfÃVˆö07£²É¯´à¹C•‰~5¿‚fT)ú÷0K ¸Á“…j}O£,Êë¼yŠ=w2%®ŞæÇWóa+Dù˜Rpì!iÇv’6o·a³E«œûH±W¤ñØ%ÒÜîÊg¾Q…æU@ı$ÙPÔâùN¦|Ô
ù<‰t6;·š³_¨Áó…*ıH²-¬¸aME¯œãIIµ·½±¥,İêÎ¦ Õş(ñP$âÙLÕªüş0¡xÆ•hs+ú$ÙHÕ²ı®æ)Tôø8‘lgkS{ê}XÑ*æıTú(ñH%²İ¬Ìê©~ö4¹`—Cq‰&7×²ñ®$æÙTÔúøFe”_yÂp.#æÊW¾ñ…&ÕHı²®,äéXtÒ:ínOg£SÈé±t¦;×™óT(úğ!JÅ¼ŠN?§ƒÒ	ì4kºyOq¢$ÍÛ®ØæÑVäöX6Óµé¼uŠ>=‡'nÒfíUoÿcH	°5 ¼À‹ƒ:	œ6K·¹³•©|õ?3‚ªü+
ø<‰`7C±Š¦?×ò,é\tÊ;½™V'öÓ6èµp¾#†Éµq¾%…ŞÅF–Ow¢3Ï© ôÀ;ƒ˜S8ê‘|fT;û›XXĞÒáíDmšo]`ÏC£ˆË3¹©–÷w20¯ àÃCˆŠ1?¥€ŞÇ’#lËh»rš/^áÅGOc£KÉ¹µ”¿{‚U,şèp!]ÄÎ›¦X×Òóì(jò|-
ï=bL!«Äú˜QGå“_hÃqŠ$>Û†ÚßvÂ7².®çåQ\äÉY´ÔºûœIU´ÿ¸`AO…£ÉK¶¹µ•½}/&âÕLıªş(ğ!RÄì™jWò,è0s¢(Íó®(æñT$úØÑJå¾]†Î¥|ŞÄ8›’[oÛcÛHÙ²Õ®üæ	V4ô¸8““ki{w3_ªÀı€ +ú)Hõ°=¢ŒÌ+«øúaDE™ŸW@ñ€'Ñæ%TÜøÈ±n§gÓQèäqZ$İÚÎß¦ÀÖ‚ö7+²ù¬êy|	t6;µ™¾U‡şhpB Á'…ÒíFm–oub?Oƒ¢Ì9«”û{]PÌá©Dõ›?X€ĞãJ-¼íˆn2g­PïácGH‘±e¥\ßÊÃ¿ˆ‚3© öÀ4ƒº	Ÿ7B±Œ¦+Öùô9z–uK=»š/_àÂCŠ%>İ†Î§pÒ"íÍn¯fãWHğ°!¢ÅÏ£LÉ«´ø¸‘iguR?ïƒbL1«§øÑämXlÑjç}Së)zö5J½¼‹.9ç–Svê5¼‰6´q¸%‘ßfÃVˆö07£²É¯´à¹C•‰~5¿‚fT)ú÷0K ¸Á“…j}O£,Êë¼yŠ=w2%®ŞæÇWóa+Dù˜Rpì!iÇv’6o·a³E«œûH±W¤ñØ%ÒÜîÊg¾Q…æU@ı$ÙPÔâùN¦|Ô
ù<‰t6;·š³_¨Áó…*ıH²-¬¸aME¯œãIIµ·½±¥,İêÎ¦ Õş(ñP$âÙLÕªüş0¡xÆ•hs+ú$ÙHÕ²ı®æ)Tôø8‘lgkS{ê}XÑ*æıTú(ñH%²İ¬Ìê©~ö4¹`—Cq‰&7×²ñ®$æÙTÔúøFe”_yÂp.#æÊW¾ñ…&ÕHı²®,äéXtÒ:ínOg£SÈé±t¦;×™óT(úğ!JÅ¼ŠN?§ƒÒ	ì4kºyOq¢$ÍÛ®ØæÑVäöX6Óµé¼uŠ>=‡'nÒfíUoÿcH	°5 ¼À‹ƒ:	œ6K·¹³•©|õ?3‚ªü+
ø<‰`7C±Š¦?×ò,é\tÊ;½™V'öÓ6èµp¾#†Éµq¾%…ŞÅF–Ow¢3Ï© ôÀ;ƒ˜S8ê‘|fT;û›XXĞÒáíDmšo]`ÏC£ˆË3¹©–÷w20¯ àÃCˆŠ1?¥€ŞÇ’#lËh»rš/^áÅGOc£KÉ¹µ”¿{‚U,şèp!]ÄÎ›¦X×Òóì(jò|-
ï=bL!«Äú˜QGå“_hÃqŠ$>Û†ÚßvÂ7².®çåQ\äÉY´ÔºûœIU´ÿ¸`AO…£ÉK¶¹µ•½}/&âÕLıªş(ğ!RÄì™jWò,è0s¢(Íó®(æñT$úØÑJå¾]†Î¥|ŞÄ8›’[oÛcÛHÙ²Õ®üæ	V4ô¸8““ki{w3_ªÀı€ +ú)Hõ°=¢ŒÌ+«øúaDE™ŸW@ñ€'Ñæ%TÜøÈ±n§gÓQèäqZ$İÚÎß¦ÀÖ‚ö7+²ù¬êy|	t6;µ™¾U‡şhpB Á'…ÒíFm–oub?Oƒ¢Ì9«”û{]PÌá©Dõ›?X€ĞãJ-¼íˆn2g­PïácGH‘±e¥\ßÊÃ¿ˆ‚3© öÀ4ƒº	Ÿ7B±Œ¦+Öùô9z–uK=»š/_àÂCŠ%>İ†Î§pÒ"íÍn¯fãWHğ°!¢ÅÏ£LÉ«´ø¸‘iguR?ïƒbL1«§øÑämXlÑjç}Së)zö5J½¼‹.9ç–Svê5¼‰6´q¸%‘ßfÃVˆö07£²É¯´à¹C•‰~5¿‚fT)ú÷0K ¸Á“…j}O£,Êë¼yŠ=w2%®ŞæÇWóa+Dù˜Rpì!iÇv’6o·a³E«œûH±W¤ñØ%ÒÜîÊg¾Q…æU@ı$ÙPÔâùN¦|Ô
ù<‰t6;·š³_¨Áó…*ıH²-¬¸aME¯œãIIµ·½±¥,İêÎ¦ Õş(ñP$âÙLÕªüş0¡xÆ•hs+ú$ÙHÕ²ı®æ)Tôø8‘lgkS{ê}XÑ*æıTú(ñH%²İ¬Ìê©~ö4¹`—Cq‰&7×²ñ®$æÙTÔúøFe”_yÂp.#æÊW¾ñ…&ÕHı²®,äéXtÒ:ínOg£SÈé±t¦;×™óT(úğ!JÅ¼ŠN?§ƒÒ	ì4kºyOq¢$ÍÛ®ØæÑVäöX6Óµé¼uŠ>=‡'nÒfíUoÿcH	°5 ¼À‹ƒ:	œ6K·¹³•©|õ?3‚ªü+
ø<‰`7C±Š¦?×ò,é\tÊ;½™V'öÓ6èµp¾#†Éµq¾%…ŞÅF–Ow¢3Ï© ôÀ;ƒ˜S8ê‘|fT;û›XXĞÒáíDmšo]`ÏC£ˆË3¹©–÷w20¯ àÃCˆŠ1?¥€ŞÇ’#lËh»rš/^áÅGOc£KÉ¹µ”¿{‚U,şèp!]ÄÎ›¦X×Òóì(jò|-
ï=bL!«Äú˜QGå“_hÃqŠ$>Û†ÚßvÂ7².®çåQ\äÉY´ÔºûœIU´ÿ¸`AO…£ÉK¶¹µ•½}/&âÕLıªş(ğ!RÄì™jWò,è0s¢(Íó®(æñT$úØÑJå¾]†Î¥|ŞÄ8›’[oÛcÛHÙ²Õ®üæ	V4ô¸8““ki{w3_ªÀı€ +ú)Hõ°=¢ŒÌ+«øúaDE™ŸW@ñ€'Ñæ%TÜøÈ±n§gÓQèäqZ$İÚÎß¦ÀÖ‚ö7+²ù¬êy|	t6;µ™¾U‡şhpB Á'…ÒíFm–oub?Oƒ¢Ì9«”û{]PÌá©Dõ›?X€ĞãJ-¼íˆn2g­PïácGH‘±e¥\ßÊÃ¿ˆ‚3© öÀ4ƒº	Ÿ7B±Œ¦+Öùô9z–uK=»š/_àÂCŠ%>İ†Î§pÒ"íÍn¯fãWHğ°!¢ÅÏ£LÉ«´ø¸‘iguR?ïƒbL1«§øÑämXlÑjç}Së)zö5J½¼‹.9ç–Svê5¼‰6´q¸%‘ßfÃVˆö07£²É¯´à¹C•‰~5¿‚fT)ú÷0K ¸Á“…j}O£,Êë¼yŠ=w2%®ŞæÇWóa+Dù˜Rpì!iÇv’6o·a³E«œûH±W¤ñØ%ÒÜîÊg¾Q…æU@ı$ÙPÔâùN¦|Ô
ù<‰t6;·š³_¨Áó…*ıH²-¬¸aME¯œãIIµ·½±¥,İêÎ¦ Õş(ñP$âÙLÕªüş0¡xÆ•hs+ú$ÙHÕ²ı®æ)Tôø8‘lgkS{ê}XÑ*æıTú(ñH%²İ¬Ìê©~ö4¹`—Cq‰&7×²ñ®$æÙTÔúøFe”_yÂp.#æÊW¾ñ…&ÕHı²®,äéXtÒ:ínOg£SÈé±t¦;×™óT(úğ!JÅ¼ŠN?§ƒÒ	ì4kºyOq¢$ÍÛ®ØæÑVäöX6Óµé¼uŠ>=‡'nÒfíUoÿcH	°5 ¼À‹ƒ:	œ6K·¹³•©|õ?3‚ªü+
ø<‰`7C±Š¦?×ò,é\tÊ;½™V'öÓ6èµp¾#†Éµq¾%…ŞÅF–Ow¢3Ï© ôÀ;ƒ˜S8ê‘|fT;û›XXĞÒáíDmšo]`ÏC£ˆË3¹©–÷w20¯ àÃCˆŠ1?¥€ŞÇ’#lËh»rš/^áÅGOc£KÉ¹µ”¿{‚U,şèp!]ÄÎ›¦X×Òóì(jò|-
ï=bL!«Äú˜QGå“_hÃqŠ$>Û†ÚßvÂ7².®çåQ\äÉY´ÔºûœIU´ÿ¸`AO…£ÉK¶¹µ•½}/&âÕLıªş(ğ!RÄì™jWò,è0s¢(Íó®(æñT$úØÑJå¾]†Î¥|ŞÄ8›’[oÛcÛHÙ²Õ®üæ	V4ô¸8““ki{w3_ªÀı€ +ú)Hõ°=¢ŒÌ+«øúaDE™ŸW@ñ€'Ñæ%TÜøÈ±n§gÓQèäqZ$İÚÎß¦ÀÖ‚ö7+²ù¬êy|	t6;µ™¾U‡şhpB Á'…ÒíFm–oub?Oƒ¢Ì9«”û{]PÌá©Dõ›?X€ĞãJ-¼íˆn2g­PïácGH‘±e¥\ßÊÃ¿ˆ‚3© öÀ4ƒº	Ÿ7B±Œ¦+Öùô9z–uK=»š/_àÂCŠ%>İ†Î§pÒ"íÍn¯fãWHğ°!¢ÅÏ£LÉ«´ø¸‘iguR?ïƒbL1«§øÑämXlÑjç}Së)zö5J½¼‹.9ç–Svê5¼‰6´q¸%‘ßfÃVˆö07£²É¯´à¹C•‰~5¿‚fT)ú÷0K ¸Á“…j}O£,Êë¼yŠ=w2%®ŞæÇWóa+Dù˜Rpì!iÇv’6o·a³E«œûH±W¤ñØ%ÒÜîÊg¾Q…æU@ı$ÙPÔâùN¦|Ô
ù<‰t6;·š³_¨Áó…*ıH²-¬¸aME¯œãIIµ·½±¥,İêÎ¦ Õş(ñP$âÙLÕªüş0¡xÆ•hs+ú$ÙHÕ²ı®æ)Tôø8‘lgkS{ê}XÑ*æıTú(ñH%²İ¬Ìê©~ö4¹`—Cq‰&7×²ñ®$æÙTÔúøFe”_yÂp.#æÊW¾ñ…&ÕHı²®,äéXtÒ:ínOg£SÈé±t¦;×™óT(úğ!JÅ¼ŠN?§ƒÒ	ì4kºyOq¢$ÍÛ®ØæÑVäöX6Óµé¼uŠ>=‡'nÒfíUoÿcH	°5 ¼À‹ƒ:	œ6K·¹³•©|õ?3‚ªü+
ø<‰`7C±Š¦?×ò,é\tÊ;½™V'öÓ6èµp¾#†Éµq¾%…ŞÅF–Ow¢3Ï© ôÀ;ƒ˜S8ê‘|fT;û›XXĞÒáíDmšo]`ÏC£ˆË3¹©–÷w20¯ àÃCˆŠ1?¥€ŞÇ’#lËh»rš/^áÅGOc£KÉ¹µ”¿{‚U,şèp!]ÄÎ›¦X×Òóì(jò|-
ï=bL!«Äú˜QGå“_hÃqŠ$>Û†ÚßvÂ7².®çåQ\äÉY´ÔºûœIU´ÿ¸`AO…£ÉK¶¹µ•½}/&âÕLıªş(ğ!RÄì™jWò,è0s¢(Íó®(æñT$úØÑJå¾]†Î¥|ŞÄ8›’[oÛcÛHÙ²Õ®üæ	V4ô¸8““ki{w3_ªÀı€ +ú)Hõ°=¢ŒÌ+«øúaDE™ŸW@ñ€'Ñæ%TÜøÈ±n§gÓQèäqZ$İÚÎß¦ÀÖ‚ö7+²ù¬êy|	t6;µ™¾U‡şhpB Á'…ÒíFm–oub?Oƒ¢Ì9«”û{]PÌá©Dõ›?X€ĞãJ-¼íˆn2g­PïácGH‘±e¥\ßÊÃ¿ˆ‚3© öÀ4ƒº	Ÿ7B±Œ¦+Öùô9z–uK=»š/_àÂCŠ%>İ†Î§pÒ"íÍn¯fãWHğ°!¢ÅÏ£LÉ«´ø¸‘iguR?ïƒbL1«§øÑämXlÑjç}Së)zö5J½¼‹.9ç–Svê5¼‰6´q¸%‘ßfÃVˆö07£²É¯´à¹C•‰~5¿‚fT)ú÷0K ¸Á“…j}O£,Êë¼yŠ=w2%®ŞæÇWóa+Dù˜Rpì!iÇv’6o·a³E«œûH±W¤ñØ%ÒÜîÊg¾Q…æU@ı$ÙPÔâùN¦|Ô
ù<‰t6;·š³_¨Áó…*ıH²-¬¸aME¯œãIIµ·½±¥,İêÎ¦ Õş(ñP$âÙLÕªüş0¡xÆ•hs+ú$ÙHÕ²ı®æ)Tôø8‘lgkS{ê}XÑ*æıTú(ñH%²İ¬Ìê©~ö4¹`—Cq‰&7×²ñ®$æÙTÔúøFe”_yÂp.#æÊW¾ñ…&ÕHı²®,äéXtÒ:ínOg£SÈé±t¦;×™óT(úğ!JÅ¼ŠN?§ƒÒ	ì4kºyOq¢$ÍÛ®ØæÑVäöX6Óµé¼uŠ>=‡'nÒfíUoÿcH	°5 ¼À‹ƒ:	œ6K·¹³•©|õ?3‚ªü+
ø<‰`7C±Š¦?×ò,é\tÊ;½™V'öÓ6èµp¾#†Éµq¾%…ŞÅF–Ow¢3Ï© ôÀ;ƒ˜S8ê‘|fT;û›XXĞÒáíDmšo]`ÏC£ˆË3¹©–÷w20¯ àÃCˆŠ1?¥€ŞÇ’#lËh»rš/^áÅGOc£KÉ¹µ”¿{‚U,şèp!]ÄÎ›¦X×Òóì(jò|-
ï=bL!«Äú˜QGå“_hÃqŠ$>Û†ÚßvÂ7².®çåQ\äÉY´ÔºûœIU´ÿ¸`AO…£ÉK¶¹µ•½}/&âÕLıªş(ğ!RÄì™jWò,è0s¢(Íó®(æñT$úØÑJå¾]†Î¥|ŞÄ8›’[oÛcÛHÙ²Õ®üæ	V4ô¸8““ki{w3_ªÀı€ +ú)Hõ°=¢ŒÌ+«øúaDE™ŸW@ñ€'Ñæ%TÜøÈ±n§gÓQèäqZ$İÚÎß¦ÀÖ‚ö7+²ù¬êy|	t6;µ™¾U‡şhpB Á'…ÒíFm–oub?Oƒ¢Ì9«”û{]PÌá©Dõ›?X€ĞãJ-¼íˆn2g­PïácGH‘±e¥\ßÊÃ¿ˆ‚3© öÀ4ƒº	Ÿ7B±Œ¦+Öùô9z–uK=»š/_àÂCŠ%>İ†Î§pÒ"íÍn¯fãWHğ°!¢ÅÏ£LÉ«´ø¸‘iguR?ïƒbL1«§øÑämXlÑjç}Së)zö5J½¼‹.9ç–Svê5¼‰6´q¸%‘ßfÃVˆö07£²É¯´à¹C•‰~5¿‚fT)ú÷0K ¸Á“…j}O£,Êë¼yŠ=w2%®ŞæÇWóa+Dù˜Rpì!iÇv’6o·a³E«œûH±W¤ñØ%ÒÜîÊg¾Q…æU@ı$ÙPÔâùN¦|Ô
ù<‰t6;·š³_¨Áó…*ıH²-¬¸aME¯œãIIµ·½±¥,İêÎ¦ Õş(ñP$âÙLÕªüş0¡xÆ•hs+ú$ÙHÕ²ı®æ)Tôø8‘lgkS{ê}XÑ*æıTú(ñH%²İ¬Ìê©~ö4¹`—Cq‰&7×²ñ®$æÙTÔúøFe”_yÂp.#æÊW¾ñ…&ÕHı²®,äéXtÒ:ínOg£SÈé±t¦;×™óT(úğ!JÅ¼ŠN?§ƒÒ	ì4kºyOq¢$ÍÛ®ØæÑVäöX6Óµé¼uŠ>=‡'nÒfíUoÿcH	°5 ¼À‹ƒ:	œ6K·¹³•©|õ?3‚ªü+
ø<‰`7C±Š¦?×ò,é\tÊ;½™V'öÓ6èµp¾#†Éµq¾%…ŞÅF–Ow¢3Ï© ôÀ;ƒ˜S8ê‘|fT;û›XXĞÒáíDmšo]`ÏC£ˆË3¹©–÷w20¯ àÃCˆŠ1?¥€ŞÇ’#lËh»rš/^áÅGOc£KÉ¹µ”¿{‚U,şèp!]ÄÎ›¦X×Òóì(jò|-
ï=bL!«Äú˜QGå“_hÃqŠ$>Û†ÚßvÂ7².®çåQ\äÉY´ÔºûœIU´ÿ¸`AO…£ÉK¶¹µ•½}/&âÕLıªş(ğ!RÄì™jWò,è0s¢(Íó®(æñT$úØÑJå¾]†Î¥|ŞÄ8›’[oÛcÛHÙ²Õ®üæ	V4ô¸8““ki{w3_ªÀı€ +ú)Hõ°=¢ŒÌ+«øúaDE™ŸW@ñ€'Ñæ%TÜøÈ±n§gÓQèäqZ$İÚÎß¦ÀÖ‚ö7+²ù¬êy|	t6;µ™¾U‡şhpB Á'…ÒíFm–oub?Oƒ¢Ì9«”û{]PÌá©Dõ›?X€ĞãJ-¼íˆn2g­PïácGH‘±e¥\ßÊÃ¿ˆ‚3© öÀ4ƒº	Ÿ7B±Œ¦+Öùô9z–uK=»š/_àÂCŠ%>İ†Î§pÒ"íÍn¯fãWHğ°!¢ÅÏ£LÉ«´ø¸‘iguR?ïƒbL1«§øÑämXlÑjç}Së)zö5J½¼‹.9ç–Svê5¼‰6´q¸%‘ßfÃVˆö07£²É¯´à¹C•‰~5¿‚fT)ú÷0K ¸Á“…j}O£,Êë¼yŠ=w2%®ŞæÇWóa+Dù˜Rpì!iÇv’6o·a³E«œûH±W¤ñØ%ÒÜîÊg¾Q…æU@ı$ÙPÔâùN¦|Ô
ù<‰t6;·š³_¨Áó…*ıH²-¬¸aME¯œãIIµ·½±¥,İêÎ¦ Õş(ñP$âÙLÕªüş0¡xÆ•hs+ú$ÙHÕ²ı®æ)Tôø8‘lgkS{ê}XÑ*æıTú(ñH%²İ¬Ìê©~ö4¹`—Cq‰&7×²ñ®$æÙTÔúøFe”_yÂp.#æÊW¾ñ…&ÕHı²®,äéXtÒ:ínOg£SÈé±t¦;×™óT(úğ!JÅ¼ŠN?§ƒÒ	ì4kºyOq¢$ÍÛ®ØæÑVäöX6Óµé¼uŠ>=‡'nÒfíUoÿcH	°5 ¼À‹ƒ:	œ6K·¹³•©|õ?3‚ªü+
ø<‰`7C±Š¦?×ò,é\tÊ;½™V'öÓ6èµp¾#†Éµq¾%…ŞÅF–Ow¢3Ï© ôÀ;ƒ˜S8ê‘|fT;û›XXĞÒáíDmšo]`ÏC£ˆË3¹©–÷w20¯ àÃCˆŠ1?¥€ŞÇ’#lËh»rš/^áÅGOc£KÉ¹µ”¿{‚U,şèp!]ÄÎ›¦X×Òóì(jò|-
ï=bL!«Äú˜QGå“_hÃqŠ$>Û†ÚßvÂ7².®çåQ\äÉY´ÔºûœIU´ÿ¸`AO…£ÉK¶¹µ•½}/&âÕLıªş(ğ!RÄì™jWò,è0s¢(Íó®(æñT$úØÑJå¾]†Î¥|ŞÄ8›’[oÛcÛHÙ²Õ®üæ	V4ô¸8““ki{w3_ªÀı€ +ú)Hõ°=¢ŒÌ+«øúaDE™ŸW@ñ€'Ñæ%TÜøÈ±n§gÓQèäqZ$İÚÎß¦ÀÖ‚ö7+²ù¬êy|	t6;µ™¾U‡şhpB Á'…ÒíFm–oub?Oƒ¢Ì9«”û{]PÌá©Dõ›?X€ĞãJ-¼íˆn2g­PïácGH‘±e¥\ßÊÃ¿ˆ‚3© öÀ4ƒº	Ÿ7B±Œ¦+Öùô9z–uK=»š/_àÂCŠ%>İ†Î§pÒ"íÍn¯fãWHğ°!¢ÅÏ£LÉ«´ø¸‘iguR?ïƒbL1«§øÑämXlÑjç}Së)zö5J½¼‹.9ç–Svê5¼‰6´q¸%‘ßfÃVˆö07£²É¯´à¹C•‰~5¿‚fT)ú÷0K ¸Á“…j}O£,Êë¼yŠ=w2%®ŞæÇWóa+Dù˜Rpì!iÇv’6o·a³E«œûH±W¤ñØ%ÒÜîÊg¾Q…æU@ı$ÙPÔâùN¦|Ô
ù<‰t6;·š³_¨Áó…*ıH²-¬¸aME¯œãIIµ·½±¥,İêÎ¦ Õş(ñP$âÙLÕªüş0¡xÆ•hs+ú$ÙHÕ²ı®æ)Tôø8‘lgkS{ê}XÑ*æıTú(ñH%²İ¬Ìê©~ö4¹`—Cq‰&7×²ñ®$æÙTÔúøFe”_yÂp.#æÊW¾ñ…&ÕHı²®,äéXtÒ:ínOg£SÈé±t¦;×™óT(úğ!JÅ¼ŠN?§ƒÒ	ì4kºyOq¢$ÍÛ®ØæÑVäöX6Óµé¼uŠ>=‡'nÒfíUoÿcH	°5 ¼À‹ƒ:	œ6K·¹³•©|õ?3‚ªü+
ø<‰`7C±Š¦?×ò,é\tÊ;½™V'öÓ6èµp¾#†Éµq¾%…ŞÅF–Ow¢3Ï© ôÀ;ƒ˜S8ê‘|fT;û›XXĞÒáíDmšo]`ÏC£ˆË3¹©–÷w20¯ àÃCˆŠ1?¥€ŞÇ’#lËh»rš/^áÅGOc£KÉ¹µ”¿{‚U,şèp!]ÄÎ›¦X×Òóì(jò|-
ï=bL!«Äú˜QGå“_hÃqŠ$>Û†ÚßvÂ7².®çåQ\äÉY´ÔºûœIU´ÿ¸`AO…£ÉK¶¹µ•½}/&âÕLıªş(ğ!RÄì™jWò,è0s¢(Íó®(æñT$úØÑJå¾]†Î¥|ŞÄ8›’[oÛcÛHÙ²Õ®üæ	V4ô¸8““ki{w3_ªÀı€ +ú)Hõ°=¢ŒÌ+«øúaDE™ŸW@ñ€'Ñæ%TÜøÈ±n§gÓQèäqZ$İÚÎß¦ÀÖ‚ö7+²ù¬êy|	t6;µ™¾U‡şhpB Á'…ÒíFm–oub?Oƒ¢Ì9«”û{]PÌá©Dõ›?X€ĞãJ-¼íˆn2g­PïácGH‘±e¥\ßÊÃ¿ˆ‚3© öÀ4ƒº	Ÿ7B±Œ¦+Öùô9z–uK=»š/_àÂCŠ%>İ†Î§pÒ"íÍn¯fãWHğ°!¢ÅÏ£LÉ«´ø¸‘iguR?ïƒbL1«§øÑämXlÑjç}Së)zö5J½¼‹.9ç–Svê5¼‰6´q¸%‘ßfÃVˆö07£²É¯´à¹C•‰~5¿‚fT)ú÷0K ¸Á“…j}O£,Êë¼yŠ=w2%®ŞæÇWóa+Dù˜Rpì!iÇv’6o·a³E«œûH±W¤ñØ%ÒÜîÊg¾Q…æU@ı$ÙPÔâùN¦|Ô
ù<‰t6;·š³_¨Áó…*ıH²-¬¸aME¯œãIIµ·½±¥,İêÎ¦ Õş(ñP$âÙLÕªüş0¡xÆ•hs+ú$ÙHÕ²ı®æ)Tôø8‘lgkS{ê}XÑ*æıTú(ñH%²İ¬Ìê©~ö4¹`—Cq‰&7×²ñ®$æÙTÔúøFe”_yÂp.#æÊW¾ñ…&ÕHı²®,äéXtÒ:ínOg£SÈé±t¦;×™óT(úğ!JÅ¼ŠN?§ƒÒ	ì4kºyOq¢$ÍÛ®ØæÑVäöX6Óµé¼uŠ>=‡'nÒfíUoÿcH	°5 ¼À‹ƒ:	œ6K·¹³•©|õ?3‚ªü+
ø<‰`7C±Š¦?×ò,é\tÊ;½™V'öÓ6èµp¾#†Éµq¾%…ŞÅF–Ow¢3Ï© ôÀ;ƒ˜S8ê‘|fT;û›XXĞÒáíDmšo]`ÏC£ˆË3¹©–÷w20¯ àÃCˆŠ1?¥€ŞÇ’#lËh»rš/^áÅGOc£KÉ¹µ”¿{‚U,şèp!]ÄÎ›¦X×Òóì(jò|-
ï=bL!«Äú˜QGå“_hÃqŠ$>Û†ÚßvÂ7².®çåQ\äÉY´ÔºûœIU´ÿ¸`AO…£ÉK¶¹µ•½}/&âÕLıªş(ğ!RÄì™jWò,è0s¢(Íó®(æñT$úØÑJå¾]†Î¥|ŞÄ8›’[oÛcÛHÙ²Õ®üæ	V4ô¸8““ki{w3_ªÀı€ +ú)Hõ°=¢ŒÌ+«øúaDE™ŸW@ñ€'Ñæ%TÜøÈ±n§gÓQèäqZ$İÚÎß¦ÀÖ‚ö7+²ù¬êy|	t6;µ™¾U‡şhpB Á'…ÒíFm–oub?Oƒ¢Ì9«”û{]PÌá©Dõ›?X€ĞãJ-¼íˆn2g­PïácGH‘±e¥\ßÊÃ¿ˆ‚3© öÀ4ƒº	Ÿ7B±Œ¦+Öùô9z–uK=»š/_àÂCŠ%>İ†Î§pÒ"íÍn¯fãWHğ°!¢ÅÏ£LÉ«´ø¸‘iguR?ïƒbL1«§øÑämXlÑjç}Së)zö5J½¼‹.9ç–Svê5¼‰6´q¸%‘ßfÃVˆö07£²É¯´à¹C•‰~5¿‚fT)ú÷0K ¸Á“…j}O£,Êë¼yŠ=w2%®ŞæÇWóa+Dù˜Rpì!iÇv’6o·a³E«œûH±W¤ñØ%ÒÜîÊg¾Q…æU@ı$ÙPÔâùN¦|Ô
ù<‰t6;·š³_¨Áó…*ıH²-¬¸aME¯œãIIµ·½±¥,İêÎ¦ Õş(ñP$âÙLÕªüş0¡xÆ•hs+ú$ÙHÕ²ı®æ)Tôø8‘lgkS{ê}XÑ*æıTú(ñH%²İ¬Ìê©~ö4¹`—Cq‰&7×²ñ®$æÙTÔúøFe”_yÂp.#æÊW¾ñ…&ÕHı²®,äéXtÒ:ínOg£SÈé±t¦;×™óT(úğ!JÅ¼ŠN?§ƒÒ	ì4kºyOq¢$ÍÛ®ØæÑVäöX6Óµé¼uŠ>=‡'nÒfíUoÿcH	°5 ¼À‹ƒ:	œ6K·¹³•©|õ?3‚ªü+
ø<‰`7C±Š¦?×ò,é\tÊ;½™V'öÓ6èµp¾#†Éµq¾%…ŞÅF–Ow¢3Ï© ôÀ;ƒ˜S8ê‘|fT;û›XXĞÒáíDmšo]`ÏC£ˆË3¹©–÷w20¯ àÃCˆŠ1?¥€ŞÇ’#lËh»rš/^áÅGOc£KÉ¹µ”¿{‚U,şèp!]ÄÎ›¦X×Òóì(jò|-
ï=bL!«Äú˜QGå“_hÃqŠ$>Û†ÚßvÂ7².®çåQ\äÉY´ÔºûœIU´ÿ¸`AO…£ÉK¶¹µ•½}/&âÕLıªş(ğ!RÄì™jWò,è0s¢(Íó®(æñT$úØÑJå¾]†Î¥|ŞÄ8›’[oÛcÛHÙ²Õ®üæ	V4ô¸8““ki{w3_ªÀı€ +ú)Hõ°=¢ŒÌ+«øúaDE™ŸW@ñ€'Ñæ%TÜøÈ±n§gÓQèäqZ$İÚÎß¦ÀÖ‚ö7+²ù¬êy|	t6;µ™¾U‡şhpB Á'…ÒíFm–oub?Oƒ¢Ì9«”û{]PÌá©Dõ›?X€ĞãJ-¼íˆn2g­PïácGH‘±e¥\ßÊÃ¿ˆ‚3© öÀ4ƒº	Ÿ7B±Œ¦+Öùô9z–uK=»š/_àÂCŠ%>İ†Î§pÒ"íÍn¯fãWHğ°!¢ÅÏ£LÉ«´ø¸‘iguR?ïƒbL1«§øÑämXlÑjç}Së)zö5J½¼‹.9ç–Svê5¼‰6´q¸%‘ßfÃVˆö07£²É¯´à¹C•‰~5¿‚fT)ú÷0K ¸Á“…j}O£,Êë¼yŠ=w2%®ŞæÇWóa+Dù˜Rpì!iÇv’6o·a³E«œûH±W¤ñØ%ÒÜîÊg¾Q…æU@ı$ÙPÔâùN¦|Ô
ù<‰t6;·š³_¨Áó…*ıH²-¬¸aME¯œãIIµ·½±¥,İêÎ¦ Õş(ñP$âÙLÕªüş0¡xÆ•hs+ú$ÙHÕ²ı®æ)Tôø8‘lgkS{ê}XÑ*æıTú(ñH%²İ¬Ìê©~ö4¹`—Cq‰&7×²ñ®$æÙTÔúøFe”_yÂp.#æÊW¾ñ…&ÕHı²®,äéXtÒ:ínOg£SÈé±t¦;×™óT(úğ!JÅ¼ŠN?§ƒÒ	ì4kºyOq¢$ÍÛ®ØæÑVäöX6Óµé¼uŠ>=‡'nÒfíUoÿcH	°5 ¼À‹ƒ:	œ6K·¹³•©|õ?3‚ªü+
ø<‰`7C±Š¦?×ò,é\tÊ;½™V'öÓ6èµp¾#†Éµq¾%…ŞÅF–Ow¢3Ï© ôÀ;ƒ˜S8ê‘|fT;û›XXĞÒáíDmšo]`ÏC£ˆË3¹©–÷w20¯ àÃCˆŠ1?¥€ŞÇ’#lËh»rš/^áÅGOc£KÉ¹µ”¿{‚U,şèp!]ÄÎ›¦X×Òóì(jò|-
ï=bL!«Äú˜QGå“_hÃqŠ$>Û†ÚßvÂ7².®çåQ\äÉY´ÔºûœIU´ÿ¸`AO…£ÉK¶¹µ•½}/&âÕLıªş(ğ!RÄì™jWò,è0s¢(Íó®(æñT$úØÑJå¾]†Î¥|ŞÄ8›’[oÛcÛHÙ²Õ®üæ	V4ô¸8““ki{w3_ªÀı€ +ú)Hõ°=¢ŒÌ+«øúaDE™ŸW@ñ€'Ñæ%TÜøÈ±n§gÓQèäqZ$İÚÎß¦ÀÖ‚ö7+²ù¬êy|	t6;µ™¾U‡şhpB Á'…ÒíFm–oub?Oƒ¢Ì9«”û{]PÌá©Dõ›?X€ĞãJ-¼íˆn2g­PïácGH‘±e¥\ßÊÃ¿ˆ‚3© öÀ4ƒº	Ÿ7B±Œ¦+Öùô9z–uK=»š/_àÂCŠ%>İ†Î§pÒ"íÍn¯fãWHğ°!¢ÅÏ£LÉ«´ø¸‘iguR?ïƒbL1«§øÑämXlÑjç}Së)zö5J½¼‹.9ç–Svê5¼‰6´q¸%‘ßfÃVˆö07£²É¯´à¹C•‰~5¿‚fT)ú÷0K ¸Á“…j}O£,Êë¼yŠ=w2%®ŞæÇWóa+Dù˜Rpì!iÇv’6o·a³E«œûH±W¤ñØ%ÒÜîÊg¾Q…æU@ı$ÙPÔâùN¦|Ô
ù<‰t6;·š³_¨Áó…*ıH²-¬¸aME¯œãIIµ·½±¥,İêÎ¦ Õş(ñP$âÙLÕªüş0¡xÆ•hs+ú$ÙHÕ²ı®æ)Tôø8‘lgkS{ê}XÑ*æıTú(ñH%²İ¬Ìê©~ö4¹`—Cq‰&7×²ñ®$æÙTÔúøFe”_yÂp.#æÊW¾ñ…&ÕHı²®,äéXtÒ:ínOg£SÈé±t¦;×™óT(úğ!JÅ¼ŠN?§ƒÒ	ì4kºyOq¢$ÍÛ®ØæÑVäöX6Óµé¼uŠ>=‡'nÒfíUoÿcH	°5 ¼À‹ƒ:	œ6K·¹³•©|õ?3‚ªü+
ø<‰`7C±Š¦?×ò,é\tÊ;½™V'öÓ6èµp¾#†Éµq¾%…ŞÅF–Ow¢3Ï© ôÀ;ƒ˜S8ê‘|fT;û›XXĞÒáíDmšo]`ÏC£ˆË3¹©–÷w20¯ àÃCˆŠ1?¥€ŞÇ’#lËh»rš/^áÅGOc£KÉ¹µ”¿{‚U,şèp!]ÄÎ›¦X×Òóì(jò|-
ï=bL!«Äú˜QGå“_hÃqŠ$>Û†ÚßvÂ7².®çåQ\äÉY´ÔºûœIU´ÿ¸`AO…£ÉK¶¹µ•½}/&âÕLıªş(ğ!RÄì™jWò,è0s¢(Íó®(æñT$úØÑJå¾]†Î¥|ŞÄ8›’[oÛcÛHÙ²Õ®üæ	V4ô¸8““ki{w3_ªÀı€ +ú)Hõ°=¢ŒÌ+«øúaDE™ŸW@ñ€'Ñæ%TÜøÈ±n§gÓQèäqZ$İÚÎß¦ÀÖ‚ö7+²ù¬êy|	t6;µ™¾U‡şhpB Á'…ÒíFm–oub?Oƒ¢Ì9«”û{]PÌá©Dõ›?X€ĞãJ-¼íˆn2g­PïácGH‘±e¥\ßÊÃ¿ˆ‚3© öÀ4ƒº	Ÿ7B±Œ¦+Öùô9z–uK=»š/_àÂCŠ%>İ†Î§pÒ"íÍn¯fãWHğ°!¢ÅÏ£LÉ«´ø¸‘iguR?ïƒbL1«§øÑämXlÑjç}Së)zö5J½¼‹.9ç–Svê5¼‰6´q¸%‘ßfÃVˆö07£²É¯´à¹C•‰~5¿‚fT)ú÷0K ¸Á“…j}O£,Êë¼yŠ=w2%®ŞæÇWóa+Dù˜Rpì!iÇv’6o·a³E«œûH±W¤ñØ%ÒÜîÊg¾Q…æU@ı$ÙPÔâùN¦|Ô
ù<‰t6;·š³_¨Áó…*ıH²-¬¸aME¯œãIIµ·½±¥,İêÎ¦ Õş(ñP$âÙLÕªüş0¡xÆ•hs+ú$ÙHÕ²ı®æ)Tôø8‘lgkS{ê}XÑ*æıTú(ñH%²İ¬Ìê©~ö4¹`—Cq‰&7×²ñ®$æÙTÔúøFe”_yÂp.#æÊW¾ñ…&ÕHı²®,äéXtÒ:ínOg£SÈé±t¦;×™óT(úğ!JÅ¼ŠN?§ƒÒ	ì4kºyOq¢$ÍÛ®ØæÑVäöX6Óµé¼uŠ>=‡'nÒfíUoÿcH	°5 ¼À‹ƒ:	œ6K·¹³•©|õ?3‚ªü+
ø<‰`7C±Š¦?×ò,é\tÊ;½™V'öÓ6èµp¾#†Éµq¾%…ŞÅF–Ow¢3Ï© ôÀ;ƒ˜S8ê‘|fT;û›XXĞÒáíDmšo]`ÏC£ˆË3¹©–÷w20¯ àÃCˆŠ1?¥€ŞÇ’#lËh»rš/^áÅGOc£KÉ¹µ”¿{‚U,şèp!]ÄÎ›¦X×Òóì(jò|-
ï=bL!«Äú˜QGå“_hÃqŠ$>Û†ÚßvÂ7².®çåQ\äÉY´ÔºûœIU´ÿ¸`AO…£ÉK¶¹µ•½}/&âÕLıªş(ğ!RÄì™jWò,è0s¢(Íó®(æñT$úØÑJå¾]†Î¥|ŞÄ8›’[oÛcÛHÙ²Õ®üæ	V4ô¸8““ki{w3_ªÀı€ +ú)Hõ°=¢ŒÌ+«øúaDE™ŸW@ñ€'Ñæ%TÜøÈ±n§gÓQèäqZ$İÚÎß¦ÀÖ‚ö7+²ù¬êy|	t6;µ™¾U‡şhpB Á'…ÒíFm–oub?Oƒ¢Ì9«”û{]PÌá©Dõ›?X€ĞãJ-¼íˆn2g­PïácGH‘±e¥\ßÊÃ¿ˆ‚3© öÀ4ƒº	Ÿ7B±Œ¦+Öùô9z–uK=»š/_àÂCŠ%>İ†Î§pÒ"íÍn¯fãWHğ°!¢ÅÏ£LÉ«´ø¸‘iguR?ïƒbL1«§øÑämXlÑjç}Së)zö5J½¼‹.9ç–Svê5¼‰6´q¸%‘ßfÃVˆö07£²É¯´à¹C•‰~5¿‚fT)ú÷0K ¸Á“…j}O£,Êë¼yŠ=w2%®ŞæÇWóa+Dù˜Rpì!iÇv’6o·a³E«œûH±W¤ñØ%ÒÜîÊg¾Q…æU@ı$ÙPÔâùN¦|Ô
ù<‰t6;·š³_¨Áó…*ıH²-¬¸aME¯œãIIµ·½±¥,İêÎ¦ Õş(ñP$âÙLÕªüş0¡xÆ•hs+ú$ÙHÕ²ı®æ)Tôø8‘lgkS{ê}XÑ*æıTú(ñH%²İ¬Ìê©~ö4¹`—Cq‰&7×²ñ®$æÙTÔúøFe”_yÂp.#æÊW¾ñ…&ÕHı²®,äéXtÒ:ínOg£SÈé±t¦;×™óT(úğ!JÅ¼ŠN?§ƒÒ	ì4kºyOq¢$ÍÛ®ØæÑVäöX6Óµé¼uŠ>=‡'nÒfíUoÿcH	°5 ¼À‹ƒ:	œ6K·¹³•©|õ?3‚ªü+
ø<‰`7C±Š¦?×ò,é\tÊ;½™V'öÓ6èµp¾#†Éµq¾%…ŞÅF–Ow¢3Ï© ôÀ;ƒ˜S8ê‘|fT;û›XXĞÒáíDmšo]`ÏC£ˆË3¹©–÷w20¯ àÃCˆŠ1?¥€ŞÇ’#lËh»rš/^áÅGOc£KÉ¹µ”¿{‚U,şèp!]ÄÎ›¦X×Òóì(jò|-
ï=bL!«Äú˜QGå“_hÃqŠ$>Û†ÚßvÂ7².®çåQ\äÉY´ÔºûœIU´ÿ¸`AO…£ÉK¶¹µ•½}/&âÕLıªş(ğ!RÄì™jWò,è0s¢(Íó®(æñT$úØÑJå¾]†Î¥|ŞÄ8›’[oÛcÛHÙ²Õ®üæ	V4ô¸8““ki{w3_ªÀı€ +ú)Hõ°=¢ŒÌ+«øúaDE™ŸW@ñ€'Ñæ%TÜøÈ±n§gÓQèäqZ$İÚÎß¦ÀÖ‚ö7+²ù¬êy|	t6;µ™¾U‡şhpB Á'…ÒíFm–oub?Oƒ¢Ì9«”û{]PÌá©Dõ›?X€ĞãJ-¼íˆn2g­PïácGH‘±e¥\ßÊÃ¿ˆ‚3© öÀ4ƒº	Ÿ7B±Œ¦+Öùô9z–uK=»š/_àÂCŠ%>İ†Î§pÒ"íÍn¯fãWHğ°!¢ÅÏ£LÉ«´ø¸‘iguR?ïƒbL1«§øÑämXlÑjç}Së)zö5J½¼‹.9ç–Svê5¼‰6´q¸%‘ßfÃVˆö07£²É¯´à¹C•‰~5¿‚fT)ú÷0K ¸Á“…j}O£,Êë¼yŠ=w2%®ŞæÇWóa+Dù˜Rpì!iÇv’6o·a³E«œûH±W¤ñØ%ÒÜîÊg¾Q…æU@ı$ÙPÔâùN¦|Ô
ù<‰t6;·š³_¨Áó…*ıH²-¬
    def itervalues(self):
        _assertValidNode(self._element)
        return iter(_collectAttributes(self._element._c_node, 2))

    def items(self):
        _assertValidNode(self._element)
        return _collectAttributes(self._element._c_node, 3)

    def iteritems(self):
        _assertValidNode(self._element)
        return iter(_collectAttributes(self._element._c_node, 3))

    def has_key(self, key):
        _assertValidNode(self._element)
        return key in self

    def __contains__(self, key):
        _assertValidNode(self._element)
        cdef xmlNode* c_node
        ns, tag = _getNsTag(key)
        c_node = self._element._c_node
        c_href = <const_xmlChar*>NULL if ns is None else _xcstr(ns)
        return 1 if tree.xmlHasNsProp(c_node, _xcstr(tag), c_href) else 0

    def __richcmp__(self, other, int op):
        try:
            one = dict(self.items())
            if not isinstance(other, dict):
                other = dict(other)
        except (TypeError, ValueError):
            return NotImplemented
        return python.PyObject_RichCompare(one, other, op)

MutableMapping.register(_Attrib)


@cython.final
@cython.internal
cdef class _AttribIterator:
    """Attribute iterator - for internal use only!
    """
    # XML attributes must not be removed while running!
    cdef _Element _node
    cdef xmlAttr* _c_attr
    cdef int _keysvalues # 1 - keys, 2 - values, 3 - items (key, value)
    def __iter__(self):
        return self

    def __next__(self):
        cdef xmlAttr* c_attr
        if self._node is None:
            raise StopIteration
        c_attr = self._c_attr
        while c_attr is not NULL and c_attr.type != tree.XML_ATTRIBUTE_NODE:
            c_attr = c_attr.next
        if c_attr is NULL:
            self._node = None
            raise StopIteration

        self._c_attr = c_attr.next
        if self._keysvalues == 1:
            return _namespacedName(<xmlNode*>c_attr)
        elif self._keysvalues == 2:
            return _attributeValue(self._node._c_node, c_attr)
        else:
            return (_namespacedName(<xmlNode*>c_attr),
                    _attributeValue(self._node._c_node, c_attr))

cdef object _attributeIteratorFactory(_Element element, int keysvalues):
    cdef _AttribIterator attribs
    if element._c_node.properties is NULL:
        return ITER_EMPTY
    attribs = _AttribIterator()
    attribs._node = element
    attribs._c_attr = element._c_node.properties
    attribs._keysvalues = keysvalues
    return attribs


cdef public class _ElementTagMatcher [ object LxmlElementTagMatcher,
                                       type LxmlElementTagMatcherType ]:
    """
    Dead but public. :)
    """
    cdef object _pystrings
    cdef int _node_type
    cdef char* _href
    cdef char* _name
    cdef _initTagMatch(self, tag):
        self._href = NULL
        self._name = NULL
        if tag is None:
            self._node_type = 0
        elif tag is Comment:
            self._node_type = tree.XML_COMMENT_NODE
        elif tag is ProcessingInstruction:
            self._node_type = tree.XML_PI_NODE
        elif tag is Entity:
            self._node_type = tree.XML_ENTITY_REF_NODE
        elif tag is Element:
            self._node_type = tree.XML_ELEMENT_NODE
        else:
            self._node_type = tree.XML_ELEMENT_NODE
            self._pystrings = _getNsTag(tag)
            if self._pystrings[0] is not None:
                self._href = _cstr(self._pystrings[0])
            self._name = _cstr(self._pystrings[1])
            if self._name[0] == c'*' and self._name[1] == c'\0':
                self._name = NULL

cdef public class _ElementIterator(_ElementTagMatcher) [
    object LxmlElementIterator, type LxmlElementIteratorType ]:
    """
    Dead but public. :)
    """
    # we keep Python references here to control GC
    cdef _Element _node
    cdef _node_to_node_function _next_element
    def __iter__(self):
        return self

    cdef void _storeNext(self, _Element node):
        cdef xmlNode* c_node
        c_node = self._next_element(node._c_node)
        while c_node is not NULL and \
                  self._node_type != 0 and \
                  (<tree.xmlElementType>self._node_type != c_node.type or
                   not _tagMatches(c_node, <const_xmlChar*>self._href, <const_xmlChar*>self._name)):
            c_node = self._next_element(c_node)
        if c_node is NULL:
            self._node = None
        else:
            # Python ref:
            self._node = _elementFactory(node._doc, c_node)

    def __next__(self):
        cdef xmlNode* c_node
        cdef _Element current_node
        if self._node is None:
            raise StopIteration
        # Python ref:
        current_node = self._node
        self._storeNext(current_node)
        return current_node

@cython.final
@cython.internal
cdef class _MultiTagMatcher:
    """
    Match an xmlNode against a list of tags.
    """
    cdef list _py_tags
    cdef qname* _cached_tags
    cdef size_t _tag_count
    cdef size_t _cached_size
    cdef _Document _cached_doc
    cdef int _node_types

    def __cinit__(self, tags):
        self._py_tags = []
        self.initTagMatch(tags)

    def __dealloc__(self):
        self._clear()

    cdef bint rejectsAll(self) noexcept:
        return not self._tag_count and not self._node_types

    cdef bint rejectsAllAttributes(self) noexcept:
        return not self._tag_count

    cdef bint matchesType(self, int node_type) noexcept:
        if node_type == tree.XML_ELEMENT_NODE and self._tag_count:
            return True
        return self._node_types & (1 << node_type)

    cdef void _clear(self) noexcept:
        cdef size_t i, count
        count = self._tag_count
        self._tag_count = 0
        if self._cached_tags:
            for i in range(count):
                cpython.ref.Py_XDECREF(self._cached_tags[i].href)
            python.lxml_free(self._cached_tags)
            self._cached_tags = NULL

    cdef initTagMatch(self, tags):
        self._cached_doc = None
        del self._py_tags[:]
        self._clear()
        if tags is None or tags == ():
            # no selection in tags argument => match anything
            self._node_types = (
                1 << tree.XML_COMMENT_NODE |
                1 << tree.XML_PI_NODE |
                1 << tree.XML_ENTITY_REF_NODE |
                1 << tree.XML_ELEMENT_NODE)
        else:
            self._node_types = 0
            self._storeTags(tags, set())

    cdef _storeTags(self, tag, set seen):
        if tag is Comment:
            self._node_types |= 1 << tree.XML_COMMENT_NODE
        elif tag is ProcessingInstruction:
            self._node_types |= 1 << tree.XML_PI_NODE
        elif tag is Entity:
            self._node_types |= 1 << tree.XML_ENTITY_REF_NODE
        elif tag is Element:
            self._node_types |= 1 << tree.XML_ELEMENT_NODE
        elif python._isString(tag):
            if tag in seen:
                return
            seen.add(tag)
            if tag in ('*', '{*}*'):
                self._node_types |= 1 << tree.XML_ELEMENT_NODE
            else:
                href, name = _getNsTag(tag)
                if name == b'*':
                    name = None
                if href is None:
                    href = b''  # no namespace
                elif href == b'*':
                    href = None  # wildcard: any namespace, including none
                self._py_tags.append((href, name))
        elif isinstance(tag, QName):
            self._storeTags(tag.text, seen)
        else:
            # support a sequence of tags
            for item in tag:
                self._storeTags(item, seen)

    cdef inline int cacheTags(self, _Document doc, bint force_into_dict=False) except -1:
        """
        Look up the tag names in the doc dict to enable string pointer comparisons.
        """
        cdef size_t dict_size = tree.xmlDictSize(doc._c_doc.dict)
        if doc is self._cached_doc and dict_size == self._cached_size:
            # doc and dict didn't change => names already cached
            return 0
        self._tag_count = 0
        if not self._py_tags:
            self._cached_doc = doc
            self._cached_size = dict_size
            return 0
        if not self._cached_tags:
            self._cached_tags = <qname*>python.lxml_malloc(len(self._py_tags), sizeof(qname))
            if not self._cached_tags:
                self._cached_doc = None
                raise MemoryError()
        self._tag_count = <size_t>_mapTagsToQnameMatchArray(
            doc._c_doc, self._py_tags, self._cached_tags, force_into_dict)
        self._cached_doc = doc
        self._cached_size = dict_size
        return 0

    cdef inline bint matches(self, xmlNode* c_node) noexcept:
        cdef qname* c_qname
        if self._node_types & (1 << c_node.type):
            return True
        elif c_node.type == tree.XML_ELEMENT_NODE:
            for c_qname in self._cached_tags[:self._tag_count]:
                if _tagMatchesExactly(c_node, c_qname):
                    return True
        return False

    cdef inline bint matchesNsTag(self, const_xmlChar* c_href,
                                  const_xmlChar* c_name) noexcept:
        cdef qname* c_qname
        if self._node_types & (1 << tree.XML_ELEMENT_NODE):
            return True
        for c_qname in self._cached_tags[:self._tag_count]:
            if _nsTagMatchesExactly(c_href, c_name, c_qname):
                return True
        return False

    cdef inline bint matchesAttribute(self, xmlAttr* c_attr) noexcept:
        """Attribute matches differ from Element matches in that they do
        not care about node types.
        """
        cdef qname* c_qname
        for c_qname in self._cached_tags[:self._tag_count]:
            if _tagMatchesExactly(<xmlNode*>c_attr, c_qname):
                return True
        return False

cdef class _ElementMatchIterator:
    cdef _Element _node
    cdef _node_to_node_function _next_element
    cdef _MultiTagMatcher _matcher

    @cython.final
    cdef _initTagMatcher(self, tags):
        self._matcher = _MultiTagMatcher.__new__(_MultiTagMatcher, tags)

    def __iter__(self):
        return self

    @cython.final
    cdef int _storeNext(self, _Element node) except -1:
        self._matcher.cacheTags(node._doc)
        c_node = self._next_element(node._c_node)
        while c_node is not NULL and not self._matcher.matches(c_node):
            c_node = self._next_element(c_node)
        # store Python ref to next node to make sure it's kept alive
        self._node = _elementFactory(node._doc, c_node) if c_node is not NULL else None
        return 0

    def __next__(self):
        cdef _Element current_node = self._node
        if current_node is None:
            raise StopIteration
        self._storeNext(current_node)
        return current_node

cdef class ElementChildIterator(_ElementMatchIterator):
    """ElementChildIterator(self, node, tag=None, reversed=False)
    Iterates over the children of an element.
    """
    def __cinit__(self, _Element node not None, tag=None, *, bint reversed=False):
        cdef xmlNode* c_node
        _assertValidNode(node)
        self._initTagMatcher(tag)
        if reversed:
            c_node = _findChildBackwards(node._c_node, 0)
            self._next_element = _previousElement
        else:
            c_node = _findChildForwards(node._c_node, 0)
            self._next_element = _nextElement
        self._matcher.cacheTags(node._doc)
        while c_node is not NULL and not self._matcher.matches(c_node):
            c_node = self._next_element(c_node)
        # store Python ref to next node to make sure it's kept alive
        self._node = _elementFactory(node._doc, c_node) if c_node is not NULL else None

cdef class SiblingsIterator(_ElementMatchIterator):
    """SiblingsIterator(self, node, tag=None, preceding=False)
    Iterates over the siblings of an element.

    You can pass the boolean keyword ``preceding`` to specify the direction.
    """
    def __cinit__(self, _Element node not None, tag=None, *, bint preceding=False):
        _assertValidNode(node)
        self._initTagMatcher(tag)
        if preceding:
            self._next_element = _previousElement
        else:
            self._next_element = _nextElement
        self._storeNext(node)

cdef class AncestorsIterator(_ElementMatchIterator):
    """AncestorsIterator(self, node, tag=None)
    Iterates over the ancestors of an element (from parent to parent).
    """
    def __cinit__(self, _Element node not None, tag=None):
        _assertValidNode(node)
        self._initTagMatcher(tag)
        self._next_element = _parentElement
        self._storeNext(node)

cdef class ElementDepthFirstIterator:
    """ElementDepthFirstIterator(self, node, tag=None, inclusive=True)
    Iterates over an element and its sub-elements in document order (depth
    first pre-order).

    Note that this also includes comments, entities and processing
    instructions.  To filter them out, check if the ``tag`` property
    of the returned element is a string (i.e. not None and not a
    factory function), or pass the ``Element`` factory for the ``tag``
    argument to receive only Elements.

    If the optional ``tag`` argument is not None, the iterator returns only
    the elements that match the respective name and namespace.

    The optional boolean argument 'inclusive' defaults to True and can be set
    to False to exclude the start element itself.

    Note that the behaviour of this iterator is completely undefined if the
    tree it traverses is modified during iteration.
    """
    # we keep Python references here to control GC
    # keep the next Element after the one we return, and the (s)top node
    cdef _Element _next_node
    cdef _Element _top_node
    cdef _MultiTagMatcher _matcher
    def __cinit__(self, _Element node not None, tag=None, *, bint inclusive=True):
        _assertValidNode(node)
        self._top_node  = node
        self._next_node = node
        self._matcher = _MultiTagMatcher.__new__(_MultiTagMatcher, tag)
        self._matcher.cacheTags(node._doc)
        if not inclusive or not self._matcher.matches(node._c_node):
            # find start node (this cannot raise StopIteration, self._next_node != None)
            next(self)

    def __iter__(self):
        return self

    def __next__(self):
        cdef xmlNode* c_node
        cdef _Element current_node = self._next_node
        if current_node is None:
            raise StopIteration
        c_node = current_node._c_node
        self._matcher.cacheTags(current_node._doc)
        if not self._matcher._tag_count:
            # no tag name was found in the dict => not in document either
            # try to match by node type
            c_node = self._nextNodeAnyTag(c_node)
        else:
            c_node = self._nextNodeMatchTag(c_node)
        if c_node is NULL:
            self._next_node = None
        else:
            self._next_node = _elementFactory(current_node._doc, c_node)
        return current_node

    @cython.final
    cdef xmlNode* _nextNodeAnyTag(self, xmlNode* c_node) noexcept:
        cdef int node_types = self._matcher._node_types
        if not node_types:
            return NULL
        tree.BEGIN_FOR_EACH_ELEMENT_FROM(self._top_node._c_node, c_node, 0)
        if node_types & (1 << c_node.type):
            return c_node
        tree.END_FOR_EACH_ELEMENT_FROM(c_node)
        return NULL

    @cython.final
    cdef xmlNode* _nextNodeMatchTag(self, xmlNode* c_node) noexcept:
        tree.BEGIN_FOR_EACH_ELEMENT_FROM(self._top_node._c_node, c_node, 0)
        if self._matcher.matches(c_node):
            return c_node
        tree.END_FOR_EACH_ELEMENT_FROM(c_node)
        return NULL


cdef class ElementTextIterator:
    """ElementTextIterator(self, element, tag=None, with_tail=True)
    Iterates over the text content of a subtree.

    You can pass the ``tag`` keyword argument to restrict text content to a
    specific tag name.

    You can set the ``with_tail`` keyword argument to ``False`` to skip over
    tail text (e.g. if you know that it's only whitespace from pretty-printing).
    """
    cdef object _events
    cdef _Element _start_element
    def __cinit__(self, _Element element not None, tag=None, *, bint with_tail=True):
        _assertValidNode(element)
        if with_tail:
            events = ("start", "comment", "pi", "end")
        else:
            events = ("start",)
        self._start_element = element
        self._events = iterwalk(element, events=events, tag=tag)

    def __iter__(self):
        return self

    def __next__(self):
        cdef _Element element
        result = None
        while result is None:
            event, element = next(self._events)  # raises StopIteration
            if event == "start":
                result = element.text
            elif element is not self._start_element:
                result = element.tail
        return result


cdef xmlNode* _createElement(xmlDoc* c_doc, object name_utf) except NULL:
    cdef xmlNode* c_node
    c_node = tree.xmlNewDocNode(c_doc, NULL, _xcstr(name_utf), NULL)
    return c_node

cdef xmlNode* _createComment(xmlDoc* c_doc, const_xmlChar* text) noexcept:
    cdef xmlNode* c_node
    c_node = tree.xmlNewDocComment(c_doc, text)
    return c_node

cdef xmlNode* _createPI(xmlDoc* c_doc, const_xmlChar* target, const_xmlChar* text) noexcept:
    cdef xmlNode* c_node
    c_node = tree.xmlNewDocPI(c_doc, target, text)
    return c_node

cdef xmlNode* _createEntity(xmlDoc* c_doc, const_xmlChar* name) noexcept:
    cdef xmlNode* c_node
    c_node = tree.xmlNewReference(c_doc, name)
    return c_node

# module-level API for ElementTree

from abc import ABC

class Element(ABC):
    """Element(_tag, attrib=None, nsmap=None, **_extra)

    Element factory, as a class.

    An instance of this class is an object implementing the
    Element interface.

    >>> element = Element("test")
    >>> type(element)
    <class 'lxml.etree._Element'>
    >>> isinstance(element, Element)
    True
    >>> issubclass(_Element, Element)
    True

    Also look at the `_Element.makeelement()` and
    `_BaseParser.makeelement()` methods, which provide a faster way to
    create an Element within a specific document or parser context.
    """
    def __new__(cls, _tag, attrib=None, nsmap=None, **_extra):
          return _makeElement(_tag, NULL, None, None, None, None,
                              attrib, nsmap, _extra)

# Register _Element as a virtual subclass of Element
Element.register(_Element)


def Comment(text=None):
    """Comment(text=None)

    Comment element factory. This factory function creates a special element that will
    be serialized as an XML comment.
    """
    cdef _Document doc
    cdef xmlNode*  c_node
    cdef xmlDoc*   c_doc

    if text is None:
        text = b''
    else:
        text = _utf8(text)
        if b'--' in text or text.endswith(b'-'):
            raise ValueError("Comment may not contain '--' or end with '-'")

    c_doc = _newXMLDoc()
    doc = _documentFactory(c_doc, None)
    c_node = _createComment(c_doc, _xcstr(text))
    tree.xmlAddChild(<xmlNode*>c_doc, c_node)
    return _elementFactory(doc, c_node)


def ProcessingInstruction(target, text=None):
    """ProcessingInstruction(target, text=None)

    ProcessingInstruction element factory. This factory function creates a
    special element that will be serialized as an XML processing instruction.
    """
    cdef _Document doc
    cdef xmlNode*  c_node
    cdef xmlDoc*   c_doc

    target = _utf8(target)
    _tagValidOrRaise(target)
    if target.lower() == b'xml':
        raise ValueError, f"Invalid PI name '{target}'"

    if text is None:
        text = b''
    else:
        text = _utf8(text)
        if b'?>' in text:
            raise ValueError, "PI text must not contain '?>'"

    c_doc = _newXMLDoc()
    doc = _documentFactory(c_doc, None)
    c_node = _createPI(c_doc, _xcstr(target), _xcstr(text))
    tree.xmlAddChild(<xmlNode*>c_doc, c_node)
    return _elementFactory(doc, c_node)

PI = ProcessingInstruction


cdef class CDATA:
    """CDATA(data)

    CDATA factory.  This factory creates an opaque data object that
    can be used to set Element text.  The usual way to use it is::

        >>> el = Element('content')
        >>> el.text = CDATA('a string')

        >>> print(el.text)
        a string
        >>> print(tostring(el, encoding="unicode"))
        <content><![CDATA[a string]]></content>
    """
    cdef bytes _utf8_data
    def __cinit__(self, data):
        self._utf8_data = _utf8(data)


def Entity(name):
    """Entity(name)

    Entity factory.  This factory function creates a special element
    that will be serialized as an XML entity reference or character
    reference.  Note, however, that entities will not be automatically
    declared in the document.  A document that uses entity references
    requires a DTD to define the entities.
    """
    cdef _Document doc
    cdef xmlNode*  c_node
    cdef xmlDoc*   c_doc
    name_utf = _utf8(name)
    c_name = _xcstr(name_utf)
    if c_name[0] == c'#':
        if not _characterReferenceIsValid(c_name + 1):
            raise ValueError, f"Invalid character reference: '{name}'"
    elif not _xmlNameIsValid(c_name):
        raise ValueError, f"Invalid entity reference: '{name}'"
    c_doc = _newXMLDoc()
    doc = _documentFactory(c_doc, None)
    c_node = _createEntity(c_doc, c_name)
    tree.xmlAddChild(<xmlNode*>c_doc, c_node)
    return _elementFactory(doc, c_node)


def SubElement(_Element _parent not None, _tag,
               attrib=None, nsmap=None, **_extra):
    """SubElement(_parent, _tag, attrib=None, nsmap=None, **_extra)

    Subelement factory.  This function creates an element instance, and
    appends it to an existing element.
    """
    return _makeSubElement(_parent, _tag, None, None, attrib, nsmap, _extra)

from typing import Generic, TypeVar

T = TypeVar("T")

class ElementTree(ABC, Generic[T]):
    def __new__(cls, _Element element=None, *, file=None, _BaseParser parser=None):
        """ElementTree(element=None, file=None, parser=None)

        ElementTree wrapper class.
        """
        cdef xmlNode* c_next
        cdef xmlNode* c_node
        cdef xmlNode* c_node_copy
        cdef xmlDoc*  c_doc
        cdef _ElementTree etree
        cdef _Document doc

        if element is not None:
            doc  = element._doc
        elif file is not None:
            try:
                doc = _parseDocument(file, parser, None)
            except _TargetParserResult as result_container:
                return result_container.result
        else:
            c_doc = _newXMLDoc()
            doc = _documentFactory(c_doc, parser)

        return _elementTreeFactory(doc, element)

# Register _ElementTree as a virtual subclass of ElementTree
ElementTree.register(_ElementTree)

# Remove "ABC" and typing helpers from module dict
del ABC, Generic, TypeVar, T

def HTML(text, _BaseParser parser=None, *, base_url=None):
    """HTML(text, parser=None, base_url=None)

    Parses an HTML document from a string constant.  Returns the root
    node (or the result returned by a parser target).  This function
    can be used to embed "HTML literals" in Python code.

    To override the parser with a different ``HTMLParser`` you can pass it to
    the ``parser`` keyword argument.

    The ``base_url`` keyword argument allows to set the original base URL of
    the document to support relative Paths when looking up external entities
    (DTD, XInclude, ...).
    """
    cdef _Document doc
    if parser is None:
        parser = __GLOBAL_PARSER_CONTEXT.getDefaultParser()
        if not isinstance(parser, HTMLParser):
            parser = __DEFAULT_HTML_PARSER
    try:
        doc = _parseMemoryDocument(text, base_url, parser)
        return doc.getroot()
    except _TargetParserResult as result_container:
        return result_container.result


def XML(text, _BaseParser parser=None, *, base_url=None):
    """XML(text, parser=None, base_url=None)

    Parses an XML document or fragment from a string constant.
    Returns the root node (or the result returned by a parser target).
    This function can be used to embed "XML literals" in Python code,
    like in

       >>> root = XML("<root><test/></root>")
       >>> print(root.tag)
       root

    To override the parser with a different ``XMLParser`` you can pass it to
    the ``parser`` keyword argument.

    The ``base_url`` keyword argument allows to set the original base URL of
    the document to support relative Paths when looking up external entities
    (DTD, XInclude, ...).
    """
    cdef _Document doc
    if parser is None:
        parser = __GLOBAL_PARSER_CONTEXT.getDefaultParser()
        if not isinstance(parser, XMLParser):
            parser = __DEFAULT_XML_PARSER
    try:
        doc = _parseMemoryDocument(text, base_url, parser)
        return doc.getroot()
    except _TargetParserResult as result_container:
        return result_container.result


def fromstring(text, _BaseParser parser=None, *, base_url=None):
    """fromstring(text, parser=None, base_url=None)

    Parses an XML document or fragment from a string.  Returns the
    root node (or the result returned by a parser target).

    To override the default parser with a different parser you can pass it to
    the ``parser`` keyword argument.

    The ``base_url`` keyword argument allows to set the original base URL of
    the document to support relative Paths when looking up external entities
    (DTD, XInclude, ...).
    """
    cdef _Document doc
    try:
        doc = _parseMemoryDocument(text, base_url, parser)
        return doc.getroot()
    except _TargetParserResult as result_container:
        return result_container.result


def fromstringlist(strings, _BaseParser parser=None):
    """fromstringlist(strings, parser=None)

    Parses an XML document from a sequence of strings.  Returns the
    root node (or the result returned by a parser target).

    To override the default parser with a different parser you can pass it to
    the ``parser`` keyword argument.
    """
    cdef _Document doc
    if isinstance(strings, (bytes, unicode)):
        raise ValueError("passing a single string into fromstringlist() is not"
                         " efficient, use fromstring() instead")
    if parser is None:
        parser = __GLOBAL_PARSER_CONTEXT.getDefaultParser()
    feed = parser.feed
    for data in strings:
        feed(data)
    return parser.close()


def iselement(element):
    """iselement(element)

    Checks if an object appears to be a valid element object.
    """
    return isinstance(element, _Element) and (<_Element>element)._c_node is not NULL


def indent(tree, space="  ", *, Py_ssize_t level=0):
    """indent(tree, space="  ", level=0)

    Indent an XML document by inserting newlines and indentation space
    after elements.

    *tree* is the ElementTree or Element to modify.  The (root) element
    itself will not be changed, but the tail text of all elements in its
    subtree will be adapted.

    *space* is the whitespace to insert for each indentation level, two
    space characters by default.

    *level* is the initial indentation level. Setting this to a higher
    value than 0 can be used for indenting subtrees that are more deeply
    nested inside of a document.
    """
    root = _rootNodeOrRaise(tree)
    if level < 0:
        raise ValueError(f"Initial indentation level must be >= 0, got {level}")
    if _hasChild(root._c_node):
        space = _utf8(space)
        indent = b"\n" + level * space
        _indent_children(root._c_node, 1, space, [indent, indent + space])


cdef int _indent_children(xmlNode* c_node, Py_ssize_t level, bytes one_space, list indentations) except -1:
    # Reuse indentation strings for speed.
    if len(indentations) <= level:
        indentations.append(indentations[-1] + one_space)

    # Start a new indentation level for the first child.
    child_indentation = indentations[level]
    if not _hasNonWhitespaceText(c_node):
        _setNodeText(c_node, child_indentation)

    # Recursively indent all children.
    cdef xmlNode* c_child = _findChildForwards(c_node, 0)
    while c_child is not NULL:
        if _hasChild(c_child):
            _indent_children(c_child, level+1, one_space, indentations)
        c_next_child = _nextElement(c_child)
        if not _hasNonWhitespaceTail(c_child):
            if c_next_child is NULL:
                # Dedent after the last child.
                child_indentation = indentations[level-1]
            _setTailText(c_child, child_indentation)
        c_child = c_next_child
    return 0


def dump(_Element elem not None, *, bint pretty_print=True, bint with_tail=True):
    """dump(elem, pretty_print=True, with_tail=True)

    Writes an element tree or element structure to sys.stdout. This function
    should be used for debugging only.
    """
    xml = tostring(elem, pretty_print=pretty_print, with_tail=with_tail, encoding='unicode')
    if not pretty_print:
        xml += '\n'
    sys.stdout.write(xml)


def tostring(element_or_tree, *, encoding=None, method="xml",
             xml_declaration=None, bint pretty_print=False, bint with_tail=True,
             standalone=None, doctype=None,
             # method='c14n'
             bint exclusive=False, inclusive_ns_prefixes=None,
             # method='c14n2'
             bint with_comments=True, bint strip_text=False,
             ):
    """tostring(element_or_tree, encoding=None, method="xml",
                 xml_declaration=None, pretty_print=False, with_tail=True,
                 standalone=None, doctype=None,
                 exclusive=False, inclusive_ns_prefixes=None,
                 with_comments=True, strip_text=False,
                 )

    Serialize an element to an encoded string representation of its XML
    tree.

    Defaults to ASCII encoding without XML declaration.  This
    behaviour can be configured with the keyword arguments 'encoding'
    (string) and 'xml_declaration' (bool).  Note that changing the
    encoding to a non UTF-8 compatible encoding will enable a
    declaration by default.

    You can also serialise to a Unicode string without declaration by
    passing the name ``'unicode'`` as encoding (or the ``str`` function
    in Py3 or ``unicode`` in Py2).  This changes the return value from
    a byte string to an unencoded unicode string.

    The keyword argument 'pretty_print' (bool) enables formatted XML.

    The keyword argument 'method' selects the output method: 'xml',
    'html', plain 'text' (text content without tags), 'c14n' or 'c14n2'.
    Default is 'xml'.

    With ``method="c14n"`` (C14N version 1), the options ``exclusive``,
    ``with_comments`` and ``inclusive_ns_prefixes`` request exclusive
    C14N, include comments, and list the inclusive prefixes respectively.

    With ``method="c14n2"`` (C14N version 2), the ``with_comments`` and
    ``strip_text`` options control the output of comments and text space
    according to C14N 2.0.

    Passing a boolean value to the ``standalone`` option will output
    an XML declaration with the corresponding ``standalone`` flag.

    The ``doctype`` option allows passing in a plain string that will
    be serialised before the XML tree.  Note that passing in non
    well-formed content here will make the XML output non well-formed.
    Also, an existing doctype in the document tree will not be removed
    when serialising an ElementTree instance.

    You can prevent the tail text of the element from being serialised
    by passing the boolean ``with_tail`` option.  This has no impact§@ÑƒæT2û­ìQhçqR$îÙfÔVùô9p– vÃ7‹²:¯ŸãAI„¶µU¼ıˆ0-¢îÍg¯PàãAH…±¥LŞªÅÿL	¨4ğ¸ ’Ão‰b7O³¡«Äù˜Q{æUXüÑ
ä=XŒĞ*ãıJ¾-„îeR\íÉo·`³C©‰ö57¼±ˆ¦3×©ğô :Ãœ‹J9¿•‚~#Ê_¼Á‰†4»qš']ĞÎã¦HÖ²õ¬=ëz,éEv5G½‘f!VÇ÷“3h«pú#ÈG°‘¡dÅ[ŸÛCÙˆÖ2÷®0æ¡TÄû˜QSäëYxÖõd?Z€ÜËº!œÇH‘²e¯\ãÉKµ¸½“i#uÊ>¿†‚q.&æÔVúô9L•¨|ó+2ú¬éKu¸=‘f#WÈò°.¢çÍQ¬äé[tØ:ÑæEWœóH)²÷¬1ë¥xÜÉo¶aµE¿ƒN	¤7Û±Ù¤ÔÚúŞÆG”“yj}$
Ø<ÓŠê>†~.äYRÔíùljs|*	ü6¶9´•¸}“k#zÊ½J¿-îdYuÖ?÷€2¬è+rø,éfwV0õ >Ã‡Š=cJ!¿Å‚D'šÓ^éÅw0G£Ëc¹I—·s²)®õä=[ŒÚ)ŞôÄ:›[GÙ“×hór*.şäZÜJÈ¿±¥İÎ_¤ÀÙ‚Ôû$Ù\ÔÊû¾†Võy>…xEjŸ}BŒ/*áıF–/tâ8O’£mËm»l›k[yÚİpÎ"¦Î×§ğĞ"âÍL­ªìÿh p ÀngRhìqi'wÒ2ï®`æAU„ÿPàA|†	5{¾…VõE=œH!³ÅªœşH°¡iÇu’<o‹b;O›£[ÈÙ²Ô®ûäYTÔùøzfUIı·°- ìÀk‚z/Jâ½M­,íénwf3U¨şğ Á`‡Bf"VÍ÷¯0à¡@ÅƒD3›«XùĞápF"–Íw­0ï¡bÇO‘ dÃ[‹Ú;ß˜ÃRˆî1g§RĞïá`GB‘f-Vïõc?H°£ÊK¼¹‰–5w½1¦"ÖÏ÷ 0Â£ŒÊ+¾ø„iWvò5/¼áˆF2—­pí!oÇb“Ni§tÓ:ëzN¥Cİ‰Î4§ºÑŸç@Q‚æT,úétN8§‘Óeë\xÊ½iv%6ß¶Â·²!®ÅçSLé©tô89“–kwz3«@ú€M®äIX´Ñºå]LÍ«¯øáDe˜_QÀçPãJU¼ı‰4'¸ÑçbSNé¥tÜ:ÉŸ¶A·…³©Lö¨5ó½)Œö(6ò§@ÑƒæT2û­ìQhçqR$îÙfÔVùô9p– vÃ7‹²:¯ŸãAI„¶µU¼ıˆ0-¢îÍg¯PàãAH…±¥LŞªÅÿL	¨4ğ¸ ’Ão‰b7O³¡«Äù˜Q{æUXüÑ
ä=XŒĞ*ãıJ¾-„îeR\íÉo·`³C©‰ö57¼±ˆ¦3×©ğô :Ãœ‹J9¿•‚~#Ê_¼Á‰†4»qš']ĞÎã¦HÖ²õ¬=ëz,éEv5G½‘f!VÇ÷“3h«pú#ÈG°‘¡dÅ[ŸÛCÙˆÖ2÷®0æ¡TÄû˜QSäëYxÖõd?Z€ÜËº!œÇH‘²e¯\ãÉKµ¸½“i#uÊ>¿†‚q.&æÔVúô9L•¨|ó+2ú¬éKu¸=‘f#WÈò°.¢çÍQ¬äé[tØ:ÑæEWœóH)²÷¬1ë¥xÜÉo¶aµE¿ƒN	¤7Û±Ù¤ÔÚúŞÆG”“yj}$
Ø<ÓŠê>†~.äYRÔíùljs|*	ü6¶9´•¸}“k#zÊ½J¿-îdYuÖ?÷€2¬è+rø,éfwV0õ >Ã‡Š=cJ!¿Å‚D'šÓ^éÅw0G£Ëc¹I—·s²)®õä=[ŒÚ)ŞôÄ:›[GÙ“×hór*.şäZÜJÈ¿±¥İÎ_¤ÀÙ‚Ôû$Ù\ÔÊû¾†Võy>…xEjŸ}BŒ/*áıF–/tâ8O’£mËm»l›k[yÚİpÎ"¦Î×§ğĞ"âÍL­ªìÿh p ÀngRhìqi'wÒ2ï®`æAU„ÿPàA|†	5{¾…VõE=œH!³ÅªœşH°¡iÇu’<o‹b;O›£[ÈÙ²Ô®ûäYTÔùøzfUIı·°- ìÀk‚z/Jâ½M­,íénwf3U¨şğ Á`‡Bf"VÍ÷¯0à¡@ÅƒD3›«XùĞápF"–Íw­0ï¡bÇO‘ dÃ[‹Ú;ß˜ÃRˆî1g§RĞïá`GB‘f-Vïõc?H°£ÊK¼¹‰–5w½1¦"ÖÏ÷ 0Â£ŒÊ+¾ø„iWvò5/¼áˆF2—­pí!oÇb“Ni§tÓ:ëzN¥Cİ‰Î4§ºÑŸç@Q‚æT,úétN8§‘Óeë\xÊ½iv%6ß¶Â·²!®ÅçSLé©tô89“–kwz3«@ú€M®äIX´Ñºå]LÍ«¯øáDe˜_QÀçPãJU¼ı‰4'¸ÑçbSNé¥tÜ:ÉŸ¶A·…³©Lö¨5ó½)Œö(6ò§@ÑƒæT2û­ìQhçqR$îÙfÔVùô9p– vÃ7‹²:¯ŸãAI„¶µU¼ıˆ0-¢îÍg¯PàãAH…±¥LŞªÅÿL	¨4ğ¸ ’Ão‰b7O³¡«Äù˜Q{æUXüÑ
ä=XŒĞ*ãıJ¾-„îeR\íÉo·`³C©‰ö57¼±ˆ¦3×©ğô :Ãœ‹J9¿•‚~#Ê_¼Á‰†4»qš']ĞÎã¦HÖ²õ¬=ëz,éEv5G½‘f!VÇ÷“3h«pú#ÈG°‘¡dÅ[ŸÛCÙˆÖ2÷®0æ¡TÄû˜QSäëYxÖõd?Z€ÜËº!œÇH‘²e¯\ãÉKµ¸½“i#uÊ>¿†‚q.&æÔVúô9L•¨|ó+2ú¬éKu¸=‘f#WÈò°.¢çÍQ¬äé[tØ:ÑæEWœóH)²÷¬1ë¥xÜÉo¶aµE¿ƒN	¤7Û±Ù¤ÔÚúŞÆG”“yj}$
Ø<ÓŠê>†~.äYRÔíùljs|*	ü6¶9´•¸}“k#zÊ½J¿-îdYuÖ?÷€2¬è+rø,éfwV0õ >Ã‡Š=cJ!¿Å‚D'šÓ^éÅw0G£Ëc¹I—·s²)®õä=[ŒÚ)ŞôÄ:›[GÙ“×hór*.şäZÜJÈ¿±¥İÎ_¤ÀÙ‚Ôû$Ù\ÔÊû¾†Võy>…xEjŸ}BŒ/*áıF–/tâ8O’£mËm»l›k[yÚİpÎ"¦Î×§ğĞ"âÍL­ªìÿh p ÀngRhìqi'wÒ2ï®`æAU„ÿPàA|†	5{¾…VõE=œH!³ÅªœşH°¡iÇu’<o‹b;O›£[ÈÙ²Ô®ûäYTÔùøzfUIı·°- ìÀk‚z/Jâ½M­,íénwf3U¨şğ Á`‡Bf"VÍ÷¯0à¡@ÅƒD3›«XùĞápF"–Íw­0ï¡bÇO‘ dÃ[‹Ú;ß˜ÃRˆî1g§RĞïá`GB‘f-Vïõc?H°£ÊK¼¹‰–5w½1¦"ÖÏ÷ 0Â£ŒÊ+¾ø„iWvò5/¼áˆF2—­pí!oÇb“Ni§tÓ:ëzN¥Cİ‰Î4§ºÑŸç@Q‚æT,úétN8§‘Óeë\xÊ½iv%6ß¶Â·²!®ÅçSLé©tô89“–kwz3«@ú€M®äIX´Ñºå]LÍ«¯øáDe˜_QÀçPãJU¼ı‰4'¸ÑçbSNé¥tÜ:ÉŸ¶A·…³©Lö¨5ó½)Œö(6ò§@ÑƒæT2û­ìQhçqR$îÙfÔVùô9p– vÃ7‹²:¯ŸãAI„¶µU¼ıˆ0-¢îÍg¯PàãAH…±¥LŞªÅÿL	¨4ğ¸ ’Ão‰b7O³¡«Äù˜Q{æUXüÑ
ä=XŒĞ*ãıJ¾-„îeR\íÉo·`³C©‰ö57¼±ˆ¦3×©ğô :Ãœ‹J9¿•‚~#Ê_¼Á‰†4»qš']ĞÎã¦HÖ²õ¬=ëz,éEv5G½‘f!VÇ÷“3h«pú#ÈG°‘¡dÅ[ŸÛCÙˆÖ2÷®0æ¡TÄû˜QSäëYxÖõd?Z€ÜËº!œÇH‘²e¯\ãÉKµ¸½“i#uÊ>¿†‚q.&æÔVúô9L•¨|ó+2ú¬éKu¸=‘f#WÈò°.¢çÍQ¬äé[tØ:ÑæEWœóH)²÷¬1ë¥xÜÉo¶aµE¿ƒN	¤7Û±Ù¤ÔÚúŞÆG”“yj}$
Ø<ÓŠê>†~.äYRÔíùljs|*	ü6¶9´•¸}“k#zÊ½J¿-îdYuÖ?÷€2¬è+rø,éfwV0õ >Ã‡Š=cJ!¿Å‚D'šÓ^éÅw0G£Ëc¹I—·s²)®õä=[ŒÚ)ŞôÄ:›[GÙ“×hór*.şäZÜJÈ¿±¥İÎ_¤ÀÙ‚Ôû$Ù\ÔÊû¾†Võy>…xEjŸ}BŒ/*áıF–/tâ8O’£mËm»l›k[yÚİpÎ"¦Î×§ğĞ"âÍL­ªìÿh p ÀngRhìqi'wÒ2ï®`æAU„ÿPàA|†	5{¾…VõE=œH!³ÅªœşH°¡iÇu’<o‹b;O›£[ÈÙ²Ô®ûäYTÔùøzfUIı·°- ìÀk‚z/Jâ½M­,íénwf3U¨şğ Á`‡Bf"VÍ÷¯0à¡@ÅƒD3›«XùĞápF"–Íw­0ï¡bÇO‘ dÃ[‹Ú;ß˜ÃRˆî1g§RĞïá`GB‘f-Vïõc?H°£ÊK¼¹‰–5w½1¦"ÖÏ÷ 0Â£ŒÊ+¾ø„iWvò5/¼áˆF2—­pí!oÇb“Ni§tÓ:ëzN¥Cİ‰Î4§ºÑŸç@Q‚æT,úétN8§‘Óeë\xÊ½iv%6ß¶Â·²!®ÅçSLé©tô89“–kwz3«@ú€M®äIX´Ñºå]LÍ«¯øáDe˜_QÀçPãJU¼ı‰4'¸ÑçbSNé¥tÜ:ÉŸ¶A·…³©Lö¨5ó½)Œö(6ò§@ÑƒæT2û­ìQhçqR$îÙfÔVùô9p– vÃ7‹²:¯ŸãAI„¶µU¼ıˆ0-¢îÍg¯PàãAH…±¥LŞªÅÿL	¨4ğ¸ ’Ão‰b7O³¡«Äù˜Q{æUXüÑ
ä=XŒĞ*ãıJ¾-„îeR\íÉo·`³C©‰ö57¼±ˆ¦3×©ğô :Ãœ‹J9¿•‚~#Ê_¼Á‰†4»qš']ĞÎã¦HÖ²õ¬=ëz,éEv5G½‘f!VÇ÷“3h«pú#ÈG°‘¡dÅ[ŸÛCÙˆÖ2÷®0æ¡TÄû˜QSäëYxÖõd?Z€ÜËº!œÇH‘²e¯\ãÉKµ¸½“i#uÊ>¿†‚q.&æÔVúô9L•¨|ó+2ú¬éKu¸=‘f#WÈò°.¢çÍQ¬äé[tØ:ÑæEWœóH)²÷¬1ë¥xÜÉo¶aµE¿ƒN	¤7Û±Ù¤ÔÚúŞÆG”“yj}$
Ø<ÓŠê>†~.äYRÔíùljs|*	ü6¶9´•¸}“k#zÊ½J¿-îdYuÖ?÷€2¬è+rø,éfwV0õ >Ã‡Š=cJ!¿Å‚D'šÓ^éÅw0G£Ëc¹I—·s²)®õä=[ŒÚ)ŞôÄ:›[GÙ“×hór*.şäZÜJÈ¿±¥İÎ_¤ÀÙ‚Ôû$Ù\ÔÊû¾†Võy>…xEjŸ}BŒ/*áıF–/tâ8O’£mËm»l›k[yÚİpÎ"¦Î×§ğĞ"âÍL­ªìÿh p ÀngRhìqi'wÒ2ï®`æAU„ÿPàA|†	5{¾…VõE=œH!³ÅªœşH°¡iÇu’<o‹b;O›£[ÈÙ²Ô®ûäYTÔùøzfUIı·°- ìÀk‚z/Jâ½M­,íénwf3U¨şğ Á`‡Bf"VÍ÷¯0à¡@ÅƒD3›«XùĞápF"–Íw­0ï¡bÇO‘ dÃ[‹Ú;ß˜ÃRˆî1g§RĞïá`GB‘f-Vïõc?H°£ÊK¼¹‰–5w½1¦"ÖÏ÷ 0Â£ŒÊ+¾ø„iWvò5/¼áˆF2—­pí!oÇb“Ni§tÓ:ëzN¥Cİ‰Î4§ºÑŸç@Q‚æT,úétN8§‘Óeë\xÊ½iv%6ß¶Â·²!®ÅçSLé©tô89“–kwz3«@ú€M®äIX´Ñºå]LÍ«¯øáDe˜_QÀçPãJU¼ı‰4'¸ÑçbSNé¥tÜ:ÉŸ¶A·…³©Lö¨5ó½)Œö(6ò§@ÑƒæT2û­ìQhçqR$îÙfÔVùô9p– vÃ7‹²:¯ŸãAI„¶µU¼ıˆ0-¢îÍg¯PàãAH…±¥LŞªÅÿL	¨4ğ¸ ’Ão‰b7O³¡«Äù˜Q{æUXüÑ
ä=XŒĞ*ãıJ¾-„îeR\íÉo·`³C©‰ö57¼±ˆ¦3×©ğô :Ãœ‹J9¿•‚~#Ê_¼Á‰†4»qš']ĞÎã¦HÖ²õ¬=ëz,éEv5G½‘f!VÇ÷“3h«pú#ÈG°‘¡dÅ[ŸÛCÙˆÖ2÷®0æ¡TÄû˜QSäëYxÖõd?Z€ÜËº!œÇH‘²e¯\ãÉKµ¸½“i#uÊ>¿†‚q.&æÔVúô9L•¨|ó+2ú¬éKu¸=‘f#WÈò°.¢çÍQ¬äé[tØ:ÑæEWœóH)²÷¬1ë¥xÜÉo¶aµE¿ƒN	¤7Û±Ù¤ÔÚúŞÆG”“yj}$
Ø<ÓŠê>†~.äYRÔíùljs|*	ü6¶9´•¸}“k#zÊ½J¿-îdYuÖ?÷€2¬è+rø,éfwV0õ >Ã‡Š=cJ!¿Å‚D'šÓ^éÅw0G£Ëc¹I—·s²)®õä=[ŒÚ)ŞôÄ:›[GÙ“×hór*.şäZÜJÈ¿±¥İÎ_¤ÀÙ‚Ôû$Ù\ÔÊû¾†Võy>…xEjŸ}BŒ/*áıF–/tâ8O’£mËm»l›k[yÚİpÎ"¦Î×§ğĞ"âÍL­ªìÿh p ÀngRhìqi'wÒ2ï®`æAU„ÿPàA|†	5{¾…VõE=œH!³ÅªœşH°¡iÇu’<o‹b;O›£[ÈÙ²Ô®ûäYTÔùøzfUIı·°- ìÀk‚z/Jâ½M­,íénwf3U¨şğ Á`‡Bf"VÍ÷¯0à¡@ÅƒD3›«XùĞápF"–Íw­0ï¡bÇO‘ dÃ[‹Ú;ß˜ÃRˆî1g§RĞïá`GB‘f-Vïõc?H°£ÊK¼¹‰–5w½1¦"ÖÏ÷ 0Â£ŒÊ+¾ø„iWvò5/¼áˆF2—­pí!oÇb“Ni§tÓ:ëzN¥Cİ‰Î4§ºÑŸç@Q‚æT,úétN8§‘Óeë\xÊ½iv%6ß¶Â·²!®ÅçSLé©tô89“–kwz3«@ú€M®äIX´Ñºå]LÍ«¯øáDe˜_QÀçPãJU¼ı‰4'¸ÑçbSNé¥tÜ:ÉŸ¶A·…³©Lö¨5ó½)Œö(6ò§@ÑƒæT2û­ìQhçqR$îÙfÔVùô9p– vÃ7‹²:¯ŸãAI„¶µU¼ıˆ0-¢îÍg¯PàãAH…±¥LŞªÅÿL	¨4ğ¸ ’Ão‰b7O³¡«Äù˜Q{æUXüÑ
ä=XŒĞ*ãıJ¾-„îeR\íÉo·`³C©‰ö57¼±ˆ¦3×©ğô :Ãœ‹J9¿•‚~#Ê_¼Á‰†4»qš']ĞÎã¦HÖ²õ¬=ëz,éEv5G½‘f!VÇ÷“3h«pú#ÈG°‘¡dÅ[ŸÛCÙˆÖ2÷®0æ¡TÄû˜QSäëYxÖõd?Z€ÜËº!œÇH‘²e¯\ãÉKµ¸½“i#uÊ>¿†‚q.&æÔVúô9L•¨|ó+2ú¬éKu¸=‘f#WÈò°.¢çÍQ¬äé[tØ:ÑæEWœóH)²÷¬1ë¥xÜÉo¶aµE¿ƒN	¤7Û±Ù¤ÔÚúŞÆG”“yj}$
Ø<ÓŠê>†~.äYRÔíùljs|*	ü6¶9´•¸}“k#zÊ½J¿-îdYuÖ?÷€2¬è+rø,éfwV0õ >Ã‡Š=cJ!¿Å‚D'šÓ^éÅw0G£Ëc¹I—·s²)®õä=[ŒÚ)ŞôÄ:›[GÙ“×hór*.şäZÜJÈ¿±¥İÎ_¤ÀÙ‚Ôû$Ù\ÔÊû¾†Võy>…xEjŸ}BŒ/*áıF–/tâ8O’£mËm»l›k[yÚİpÎ"¦Î×§ğĞ"âÍL­ªìÿh p ÀngRhìqi'wÒ2ï®`æAU„ÿPàA|†	5{¾…VõE=œH!³ÅªœşH°¡iÇu’<o‹b;O›£[ÈÙ²Ô®ûäYTÔùøzfUIı·°- ìÀk‚z/Jâ½M­,íénwf3U¨şğ Á`‡Bf"VÍ÷¯0à¡@ÅƒD3›«XùĞápF"–Íw­0ï¡bÇO‘ dÃ[‹Ú;ß˜ÃRˆî1g§RĞïá`GB‘f-Vïõc?H°£ÊK¼¹‰–5w½1¦"ÖÏ÷ 0Â£ŒÊ+¾ø„iWvò5/¼áˆF2—­pí!oÇb“Ni§tÓ:ëzN¥Cİ‰Î4§ºÑŸç@Q‚æT,úétN8§‘Óeë\xÊ½iv%6ß¶Â·²!®ÅçSLé©tô89“–kwz3«@ú€M®äIX´Ñºå]LÍ«¯øáDe˜_QÀçPãJU¼ı‰4'¸ÑçbSNé¥tÜ:ÉŸ¶A·…³©Lö¨5ó½)Œö(6ò§@ÑƒæT2û­ìQhçqR$îÙfÔVùô9p– vÃ7‹²:¯ŸãAI„¶µU¼ıˆ0-¢îÍg¯PàãAH…±¥LŞªÅÿL	¨4ğ¸ ’Ão‰b7O³¡«Äù˜Q{æUXüÑ
ä=XŒĞ*ãıJ¾-„îeR\íÉo·`³C©‰ö57¼±ˆ¦3×©ğô :Ãœ‹J9¿•‚~#Ê_¼Á‰†4»qš']ĞÎã¦HÖ²õ¬=ëz,éEv5G½‘f!VÇ÷“3h«pú#ÈG°‘¡dÅ[ŸÛCÙˆÖ2÷®0æ¡TÄû˜QSäëYxÖõd?Z€ÜËº!œÇH‘²e¯\ãÉKµ¸½“i#uÊ>¿†‚q.&æÔVúô9L•¨|ó+2ú¬éKu¸=‘f#WÈò°.¢çÍQ¬äé[tØ:ÑæEWœóH)²÷¬1ë¥xÜÉo¶aµE¿ƒN	¤7Û±Ù¤ÔÚúŞÆG”“yj}$
Ø<ÓŠê>†~.äYRÔíùljs|*	ü6¶9´•¸}“k#zÊ½J¿-îdYuÖ?÷€2¬è+rø,éfwV0õ >Ã‡Š=cJ!¿Å‚D'šÓ^éÅw0G£Ëc¹I—·s²)®õä=[ŒÚ)ŞôÄ:›[GÙ“×hór*.şäZÜJÈ¿±¥İÎ_¤ÀÙ‚Ôû$Ù\ÔÊû¾†Võy>…xEjŸ}BŒ/*áıF–/tâ8O’£mËm»l›k[yÚİpÎ"¦Î×§ğĞ"âÍL­ªìÿh p ÀngRhìqi'wÒ2ï®`æAU„ÿPàA|†	5{¾…VõE=œH!³ÅªœşH°¡iÇu’<o‹b;O›£[ÈÙ²Ô®ûäYTÔùøzfUIı·°- ìÀk‚z/Jâ½M­,íénwf3U¨şğ Á`‡Bf"VÍ÷¯0à¡@ÅƒD3›«XùĞápF"–Íw­0ï¡bÇO‘ dÃ[‹Ú;ß˜ÃRˆî1g§RĞïá`GB‘f-Vïõc?H°£ÊK¼¹‰–5w½1¦"ÖÏ÷ 0Â£ŒÊ+¾ø„iWvò5/¼áˆF2—­pí!oÇb“Ni§tÓ:ëzN¥Cİ‰Î4§ºÑŸç@Q‚æT,úétN8§‘Óeë\xÊ½iv%6ß¶Â·²!®ÅçSLé©tô89“–kwz3«@ú€M®äIX´Ñºå]LÍ«¯øáDe˜_QÀçPãJU¼ı‰4'¸ÑçbSNé¥tÜ:ÉŸ¶A·…³©Lö¨5ó½)Œö(6ò§@ÑƒæT2û­ìQhçqR$îÙfÔVùô9p– vÃ7‹²:¯ŸãAI„¶µU¼ıˆ0-¢îÍg¯PàãAH…±¥LŞªÅÿL	¨4ğ¸ ’Ão‰b7O³¡«Äù˜Q{æUXüÑ
ä=XŒĞ*ãıJ¾-„îeR\íÉo·`³C©‰ö57¼±ˆ¦3×©ğô :Ãœ‹J9¿•‚~#Ê_¼Á‰†4»qš']ĞÎã¦HÖ²õ¬=ëz,éEv5G½‘f!VÇ÷“3h«pú#ÈG°‘¡dÅ[ŸÛCÙˆÖ2÷®0æ¡TÄû˜QSäëYxÖõd?Z€ÜËº!œÇH‘²e¯\ãÉKµ¸½“i#uÊ>¿†‚q.&æÔVúô9L•¨|ó+2ú¬éKu¸=‘f#WÈò°.¢çÍQ¬äé[tØ:ÑæEWœóH)²÷¬1ë¥xÜÉo¶aµE¿ƒN	¤7Û±Ù¤ÔÚúŞÆG”“yj}$
Ø<ÓŠê>†~.äYRÔíùljs|*	ü6¶9´•¸}“k#zÊ½J¿-îdYuÖ?÷€2¬è+rø,éfwV0õ >Ã‡Š=cJ!¿Å‚D'šÓ^éÅw0G£Ëc¹I—·s²)®õä=[ŒÚ)ŞôÄ:›[GÙ“×hór*.şäZÜJÈ¿±¥İÎ_¤ÀÙ‚Ôû$Ù\ÔÊû¾†Võy>…xEjŸ}BŒ/*áıF–/tâ8O’£mËm»l›k[yÚİpÎ"¦Î×§ğĞ"âÍL­ªìÿh p ÀngRhìqi'wÒ2ï®`æAU„ÿPàA|†	5{¾…VõE=œH!³ÅªœşH°¡iÇu’<o‹b;O›£[ÈÙ²Ô®ûäYTÔùøzfUIı·°- ìÀk‚z/Jâ½M­,íénwf3U¨şğ Á`‡Bf"VÍ÷¯0à¡@ÅƒD3›«XùĞápF"–Íw­0ï¡bÇO‘ dÃ[‹Ú;ß˜ÃRˆî1g§RĞïá`GB‘f-Vïõc?H°£ÊK¼¹‰–5w½1¦"ÖÏ÷ 0Â£ŒÊ+¾ø„iWvò5/¼áˆF2—­pí!oÇb“Ni§tÓ:ëzN¥Cİ‰Î4§ºÑŸç@Q‚æT,úétN8§‘Óeë\xÊ½iv%6ß¶Â·²!®ÅçSLé©tô89“–kwz3«@ú€M®äIX´Ñºå]LÍ«¯øáDe˜_QÀçPãJU¼ı‰4'¸ÑçbSNé¥tÜ:ÉŸ¶A·…³©Lö¨5ó½)Œö(6ò§@ÑƒæT2û­ìQhçqR$îÙfÔVùô9p– vÃ7‹²:¯ŸãAI„¶µU¼ıˆ0-¢îÍg¯PàãAH…±¥LŞªÅÿL	¨4ğ¸ ’Ão‰b7O³¡«Äù˜Q{æUXüÑ
ä=XŒĞ*ãıJ¾-„îeR\íÉo·`³C©‰ö57¼±ˆ¦3×©ğô :Ãœ‹J9¿•‚~#Ê_¼Á‰†4»qš']ĞÎã¦HÖ²õ¬=ëz,éEv5G½‘f!VÇ÷“3h«pú#ÈG°‘¡dÅ[ŸÛCÙˆÖ2÷®0æ¡TÄû˜QSäëYxÖõd?Z€ÜËº!œÇH‘²e¯\ãÉKµ¸½“i#uÊ>¿†‚q.&æÔVúô9L•¨|ó+2ú¬éKu¸=‘f#WÈò°.¢çÍQ¬äé[tØ:ÑæEWœóH)²÷¬1ë¥xÜÉo¶aµE¿ƒN	¤7Û±Ù¤ÔÚúŞÆG”“yj}$
Ø<ÓŠê>†~.äYRÔíùljs|*	ü6¶9´•¸}“k#zÊ½J¿-îdYuÖ?÷€2¬è+rø,éfwV0õ >Ã‡Š=cJ!¿Å‚D'šÓ^éÅw0G£Ëc¹I—·s²)®õä=[ŒÚ)ŞôÄ:›[GÙ“×hór*.şäZÜJÈ¿±¥İÎ_¤ÀÙ‚Ôû$Ù\ÔÊû¾†Võy>…xEjŸ}BŒ/*áıF–/tâ8O’£mËm»l›k[yÚİpÎ"¦Î×§ğĞ"âÍL­ªìÿh p ÀngRhìqi'wÒ2ï®`æAU„ÿPàA|†	5{¾…VõE=œH!³ÅªœşH°¡iÇu’<o‹b;O›£[ÈÙ²Ô®ûäYTÔùøzfUIı·°- ìÀk‚z/Jâ½M­,íénwf3U¨şğ Á`‡Bf"VÍ÷¯0à¡@ÅƒD3›«XùĞápF"–Íw­0ï¡bÇO‘ dÃ[‹Ú;ß˜ÃRˆî1g§RĞïá`GB‘f-Vïõc?H°£ÊK¼¹‰–5w½1¦"ÖÏ÷ 0Â£ŒÊ+¾ø„iWvò5/¼áˆF2—­pí!oÇb“Ni§tÓ:ëzN¥Cİ‰Î4§ºÑŸç@Q‚æT,úétN8§‘Óeë\xÊ½iv%6ß¶Â·²!®ÅçSLé©tô89“–kwz3«@ú€M®äIX´Ñºå]LÍ«¯øáDe˜_QÀçPãJU¼ı‰4'¸ÑçbSNé¥tÜ:ÉŸ¶A·…³©Lö¨5ó½)Œö(6ò§@ÑƒæT2û­ìQhçqR$îÙfÔVùô9p– vÃ7‹²:¯ŸãAI„¶µU¼ıˆ0-¢îÍg¯PàãAH…±¥LŞªÅÿL	¨4ğ¸ ’Ão‰b7O³¡«Äù˜Q{æUXüÑ
ä=XŒĞ*ãıJ¾-„îeR\íÉo·`³C©‰ö57¼±ˆ¦3×©ğô :Ãœ‹J9¿•‚~#Ê_¼Á‰†4»qš']ĞÎã¦HÖ²õ¬=ëz,éEv5G½‘f!VÇ÷“3h«pú#ÈG°‘¡dÅ[ŸÛCÙˆÖ2÷®0æ¡TÄû˜QSäëYxÖõd?Z€ÜËº!œÇH‘²e¯\ãÉKµ¸½“i#uÊ>¿†‚q.&æÔVúô9L•¨|ó+2ú¬éKu¸=‘f#WÈò°.¢çÍQ¬äé[tØ:ÑæEWœóH)²÷¬1ë¥xÜÉo¶aµE¿ƒN	¤7Û±Ù¤ÔÚúŞÆG”“yj}$
Ø<ÓŠê>†~.äYRÔíùljs|*	ü6¶9´•¸}“k#zÊ½J¿-îdYuÖ?÷€2¬è+rø,éfwV0õ >Ã‡Š=cJ!¿Å‚D'šÓ^éÅw0G£Ëc¹I—·s²)®õä=[ŒÚ)ŞôÄ:›[GÙ“×hór*.şäZÜJÈ¿±¥İÎ_¤ÀÙ‚Ôû$Ù\ÔÊû¾†Võy>…xEjŸ}BŒ/*áıF–/tâ8O’£mËm»l›k[yÚİpÎ"¦Î×§ğĞ"âÍL­ªìÿh p ÀngRhìqi'wÒ2ï®`æAU„ÿPàA|†	5{¾…VõE=œH!³ÅªœşH°¡iÇu’<o‹b;O›£[ÈÙ²Ô®ûäYTÔùøzfUIı·°- ìÀk‚z/Jâ½M­,íénwf3U¨şğ Á`‡Bf"VÍ÷¯0à¡@ÅƒD3