# XSLT
from lxml.includes cimport xslt


cdef class XSLTError(LxmlError):
    """Base class of all XSLT errors.
    """

cdef class XSLTParseError(XSLTError):
    """Error parsing a stylesheet document.
    """

cdef class XSLTApplyError(XSLTError):
    """Error running an XSL transformation.
    """

class XSLTSaveError(XSLTError, SerialisationError):
    """Error serialising an XSLT result.
    """

cdef class XSLTExtensionError(XSLTError):
    """Error registering an XSLT extension.
    """


# version information
LIBXSLT_COMPILED_VERSION = __unpackIntVersion(xslt.LIBXSLT_VERSION)
LIBXSLT_VERSION = __unpackIntVersion(xslt.xsltLibxsltVersion)


################################################################################
# Where do we store what?
#
# xsltStylesheet->doc->_private
#    == _XSLTResolverContext for XSL stylesheet
#
# xsltTransformContext->_private
#    == _XSLTResolverContext for transformed document
#
################################################################################


################################################################################
# XSLT document loaders

@cython.final
@cython.internal
cdef class _XSLTResolverContext(_ResolverContext):
    cdef xmlDoc* _c_style_doc
    cdef _BaseParser _parser

    @cython.final
    cdef _XSLTResolverContext _copy(self):
        cdef _XSLTResolverContext context
        context = _XSLTResolverContext()
        _initXSLTResolverContext(context, self._parser)
        context._c_style_doc = self._c_style_doc
        return context


cdef _initXSLTResolverContext(_XSLTResolverContext context,
                              _BaseParser parser):
    _initResolverContext(context, parser.resolvers)
    context._parser = parser
    context._c_style_doc = NULL

cdef xmlDoc* _xslt_resolve_from_python(const_xmlChar* c_uri, void* c_context,
                                       int parse_options, int* error) noexcept with gil:
    # call the Python document loaders
    cdef _XSLTResolverContext context
    cdef _ResolverRegistry resolvers
    cdef _InputDocument doc_ref
    cdef xmlDoc* c_doc
    cdef xmlDoc* c_return_doc = NULL

    error[0] = 0
    context = <_XSLTResolverContext>c_context

    # shortcut if we resolve the stylesheet itself
    c_doc = context._c_style_doc
    try:
        if c_doc is not NULL and c_doc.URL is not NULL:
            if tree.xmlStrcmp(c_uri, c_doc.URL) == 0:
                c_return_doc = _copyDoc(c_doc, 1)
                return c_return_doc  # 'goto', see 'finally' below

        # delegate to the Python resolvers
        resolvers = context._resolvers
        if tree.xmlStrncmp(<unsigned char*>'string://__STRING__XSLT__/', c_uri, 26) == 0:
            c_uri += 26
        uri = _decodeFilename(c_uri)
        doc_ref = resolvers.resolve(uri, None, context)

        if doc_ref is not None:
            if doc_ref._type == PARSER_DATA_STRING:
                c_return_doc = _parseDoc(
                    doc_ref._data_bytes, doc_ref._filename, context._parser)
            elif doc_ref._type == PARSER_DATA_FILENAME:
                c_return_doc = _parseDocFromFile(
                    doc_ref._filename, context._parser)
            elif doc_ref._type == PARSER_DATA_FILE:
                c_return_doc = _parseDocFromFilelike(
                    doc_ref._file, doc_ref._filename, context._parser)
            elif doc_ref._type == PARSER_DATA_EMPTY:
                c_return_doc = _newXMLDoc()
            if c_return_doc is not NULL and c_return_doc.URL is NULL:
                c_return_doc.URL = tree.xmlStrdup(c_uri)
    except:
        error[0] = 1
        context._store_raised()
    finally:
        return c_return_doc  # and swallow any further exceptions


cdef void _xslt_store_resolver_exception(const_xmlChar* c_uri, void* context,
                                         xslt.xsltLoadType c_type) noexcept with gil:
    try:
        message = f"Cannot resolve URI {_decodeFilename(c_uri)}"
        if c_type == xslt.XSLT_LOAD_DOCUMENT:
            exception = XSLTApplyError(message)
        else:
            exception = XSLTParseError(message)
        (<_XSLTResolverContext>context)._store_exception(exception)
    except BaseException as e:
        (<_XSLTResolverContext>context)._store_exception(e)
    finally:
        return  # and swallow any further exceptions


cdef xmlDoc* _xslt_doc_loader(const_xmlChar* c_uri, tree.xmlDict* c_dict,
                              int parse_options, void* c_ctxt,
                              xslt.xsltLoadType c_type) noexcept nogil:
    # nogil => no Python objects here, may be called without thread context !
    cdef xmlDoc* c_doc
    cdef xmlDoc* result
    cdef void* c_pcontext
    cdef int error = 0
    # find resolver contexts of stylesheet and transformed doc
    if c_type == xslt.XSLT_LOAD_DOCUMENT:
        # transformation time
        c_pcontext = (<xslt.xsltTransformContext*>c_ctxt)._private
    elif c_type == xslt.XSLT_LOAD_STYLESHEET:
        # include/import resolution while parsing
        c_pcontext = (<xslt.xsltStylesheet*>c_ctxt).doc._private
    else:
        c_pcontext = NULL

    if c_pcontext is NULL:
        # can't call Python without context, fall back to default loader
        return XSLT_DOC_DEFAULT_LOADER(
            c_uri, c_dict, parse_options, c_ctxt, c_type)

    c_doc = _xslt_resolve_from_python(c_uri, c_pcontext, parse_options, &error)
    if c_doc is NULL and not error:
        c_doc = XSLT_DOC_DEFAULT_LOADER(
            c_uri, c_dict, parse_options, c_ctxt, c_type)
        if c_doc is NULL:
            _xslt_store_resolver_exception(c_uri, c_pcontext, c_type)

    if c_doc is not NULL and c_type == xslt.XSLT_LOAD_STYLESHEET:
        c_doc._private = c_pcontext
    return c_doc

cdef xslt.xsltDocLoaderFunc XSLT_DOC_DEFAULT_LOADER = xslt.xsltDocDefaultLoader
xslt.xsltSetLoaderFunc(<xslt.xsltDocLoaderFunc>_xslt_doc_loader)

################################################################################
# XSLT file/network access control

cdef class XSLTAccessControl:
    """XSLTAccessControl(self, read_file=True, write_file=True, create_dir=True, read_network=True, write_network=True)

    Access control for XSLT: reading/writing files, directories and
    network I/O.  Access to a type of resource is granted or denied by
    passing any of the following boolean keyword arguments.  All of
    them default to True to allow access.

    - read_file
    - write_file
    - create_dir
    - read_network
    - write_network

    For convenience, there is also a class member `DENY_ALL` that
    provides an XSLTAccessControl instance that is readily configured
    to deny everything, and a `DENY_WRITE` member that denies all
    write access but allows read access.

    See `XSLT`.
    """
    cdef xslt.xsltSecurityPrefs* _prefs
    def __cinit__(self):
        self._prefs = xslt.xsltNewSecurityPrefs()
        if self._prefs is NULL:
            raise MemoryError()

    def __init__(self, *, bint read_file=True, bint write_file=True, bint create_dir=True,
                 bint read_network=True, bint write_network=True):
        self._setAccess(xslt.XSLT_SECPREF_READ_FILE, read_file)
        self._setAccess(xslt.XSLT_SECPREF_WRITE_FILE, write_file)
        self._setAccess(xslt.XSLT_SECPREF_CREATE_DIRECTORY, create_dir)
        self._setAccess(xslt.XSLT_SECPREF_READ_NETWORK, read_network)
        self._setAccess(xslt.XSLT_SECPREF_WRITE_NETWORK, write_network)

    DENY_ALL = XSLTAccessControl(
        read_file=False, write_file=False, create_dir=False,
        read_network=False, write_network=False)

    DENY_WRITE = XSLTAccessControl(
        read_file=True, write_file=False, create_dir=False,
        read_network=True, write_network=False)

    def __dealloc__(self):
        if self._prefs is not NULL:
            xslt.xsltFreeSecurityPrefs(self._prefs)

    @cython.final
    cdef _setAccess(self, xslt.xsltSecurityOption option, bint allow):
        cdef xslt.xsltSecurityCheck function
        if allow:
            function = xslt.xsltSecurityAllow
        else:
            function = xslt.xsltSecurityForbid
        xslt.xsltSetSecurityPrefs(self._prefs, option, function)

    @cython.final
    cdef void _register_in_context(self, xslt.xsltTransformContext* ctxt) noexcept:
        xslt.xsltSetCtxtSecurityPrefs(self._prefs, ctxt)

    @property
    def options(self):
        """The access control configuration as a map of options."""
        return {
            'read_file': self._optval(xslt.XSLT_SECPREF_READ_FILE),
            'write_file': self._optval(xslt.XSLT_SECPREF_WRITE_FILE),
            'create_dir': self._optval(xslt.XSLT_SECPREF_CREATE_DIRECTORY),
            'read_network': self._optval(xslt.XSLT_SECPREF_READ_NETWORK),
            'write_network': self._optval(xslt.XSLT_SECPREF_WRITE_NETWORK),
        }

    @cython.final
    cdef _optval(self, xslt.xsltSecurityOption option):
        cdef xslt.xsltSecurityCheck function
        function = xslt.xsltGetSecurityPrefs(self._prefs, option)
        if function is <xslt.xsltSecurityCheck>xslt.xsltSecurityAllow:
            return True
        elif function is <xslt.xsltSecurityCheck>xslt.xsltSecurityForbid:
            return False
        else:
            return None

    def __repr__(self):
        items = sorted(self.options.items())
        return "%s(%s)" % (
            python._fqtypename(self).decode('UTF-8').split('.')[-1],
            ', '.join(["%s=%r" % item for item in items]))

################################################################################
# XSLT

cdef int _register_xslt_function(void* ctxt, name_utf, ns_utf) noexcept:
    if ns_utf is None:
        return 0
    # libxml2 internalises the strings if ctxt has a dict
    return xslt.xsltRegisterExtFunction(
        <xslt.xsltTransformContext*>ctxt, _xcstr(name_utf), _xcstr(ns_utf),
        <xslt.xmlXPathFunction>_xpath_function_call)

cdef dict EMPTY_DICT = {}

@cython.final
@cython.internal
cdef class _XSLTContext(_BaseContext):
    cdef xslt.xsltTransformContext* _xsltCtxt
    cdef _ReadOnlyElementProxy _extension_element_proxy
    cdef dict _extension_elements
    def __cinit__(self):
        self._xsltCtxt = NULL
        self._extension_elements = EMPTY_DICT

    def __init__(self, namespaces, extensions, error_log, enable_regexp,
                 build_smart_strings):
        if extensions is not None and extensions:
            for ns_name_tuple, extension in extensions.items():
                if ns_name_tuple[0] is None:
                    raise XSLTExtensionError, \
                        "extensions must not have empty namespaces"
                if isinstance(extension, XSLTExtension):
                    if self._extension_elements is EMPTY_DICT:
                        self._extension_elements = {}
                        extensions = extensions.copy()
                    ns_utf   = _utf8(ns_name_tuple[0])
                    name_utf = _utf8(ns_name_tuple[1])
                    self._extension_elements[(ns_utf, name_utf)] = extension
                    del extensions[ns_name_tuple]
        _BaseContext.__init__(self, namespaces, extensions, error_log, enable_regexp,
                              build_smart_strings)

    cdef _BaseContext _copy(self):
        cdef _XSLTContext context
        context = <_XSLTContext>_BaseContext._copy(self)
        context._extension_elements = self._extension_elements
        return context

    cdef register_context(self, xslt.xsltTransformContext* xsltCtxt,
                               _Document doc):
        self._xsltCtxt = xsltCtxt
        self._set_xpath_context(xsltCtxt.xpathCtxt)
        self._register_context(doc)
        self.registerLocalFunctions(xsltCtxt, _register_xslt_function)
        self.registerGlobalFunctions(xsltCtxt, _register_xslt_function)
        _registerXSLTExtensions(xsltCtxt, self._extension_elements)

    cdef free_context(self):
        self._cleanup_context()
        self._release_context()
        if self._xsltCtxt is not NULL:
            xslt.xsltFreeTransformContext(self._xsltCtxt)
            self._xsltCtxt = NULL
        self._release_temp_refs()


@cython.final
@cython.internal
@cython.freelist(8)
cdef class _XSLTQuotedStringParam:
    """A wrapper class for literal XSLT string parameters that require
    quote escaping.
    """
    cdef bytes strval
    def __cinit__(self, strval):
        self.strval = _utf8(strval)


@cython.no_gc_clear
cdef class XSLT:
    """XSLT(self, xslt_input, extensions=None, regexp=True, access_control=None)

    Turn an XSL document into an XSLT object.

    Calling this object on a tree or Element will execute the XSLT::

        transform = etree.XSLT(xsl_tree)
        result = transform(xml_tree)

    Keyword arguments of the constructor:

    - extensions: a dict mapping ``(namespace, name)`` pairs to
      extension functions or extension elements
    - regexp: enable exslt regular expression support in XPath
      (default: True)
    - access_control: access restrictions for network or file
      system (see `XSLTAccessControl`)

    Keyword arguments of the XSLT call:

    - profile_run: enable XSLT profiling and make the profile available
      as XML document in ``result.xslt_profile`` (default: False)

    Other keyword arguments of the call are passed to the stylesheet
    as parameters.
    """
    cdef _XSLTContext _context
    cdef xslt.xsltStylesheet* _c_style
    cdef _XSLTResolverContext _xslt_resolver_context
    cdef XSLTAccessControl _access_control
    cdef _ErrorLog _error_log

    def __cinit__(self):
        self._c_style = NULL

    def __init__(self, xslt_input, *, extensions=None, regexp=True,
                 access_control=None):
        cdef xslt.xsltStylesheet* c_style = NULL
        cdef xmlDoc* c_doc
        cdef _Document doc
        cdef _Element root_node

        doc = _documentOrRaise(xslt_input)
        root_node = _rootNodeOrRaise(xslt_input)

        # set access control or raise TypeError
        self._access_control = access_control

        # make a copy of the document as stylesheet parsing modifies it
        c_doc = _copyDocRoot(doc._c_doc, root_node._c_node)

        # make sure we always have a stylesheet URL
        if c_doc.URL is NULL:
            doc_url_utf = python.PyUnicode_AsASCIIString(
                f"string://__STRING__XSLT__/{id(self)}.xslt")
            c_doc.URL = tree.xmlStrdup(_xcstr(doc_url_utf))

        self._error_log = _ErrorLog()
        self._xslt_resolver_context = _XSLTResolverContext()
        _initXSLTResolverContext(self._xslt_resolver_context, doc._parser)
        # keep a copy in case we need to access the stylesheet via 'document()'
        self._xslt_resolver_context._c_style_doc = _copyDoc(c_doc, 1)
        c_doc._private = <python.PyObject*>self._xslt_resolver_context

        with self._error_log:
            orig_loader = _register_document_loader()
            c_style = xslt.xsltParseStylesheetDoc(c_doc)
            _reset_document_loader(orig_loader)

        if c_style is NULL or c_style.errors:
            tree.xmlFreeDoc(c_doc)
            if c_style is not NULL:
                xslt.xsltFreeStylesheet(c_style)
            self._xslt_resolver_context._raise_if_stored()
            # last error seems to be the most accurate here
            if self._error_log.last_error is not None and \
                    self._error_log.last_error.message:
                raise XSLTParseError(self._error_log.last_error.message,
                                     self._error_log)
            else:
                raise XSLTParseError(
                    self._error_log._buildExceptionMessage(
                        "Cannot parse stylesheet"),
                    self._error_log)

        c_doc._private = NULL # no longer used!
        self._c_style = c_style
        self._context = _XSLTContext(None, extensions, self._error_log, regexp, True)

    g«PûàAX„Ñå]^ÌÅ«œûK¸UÿaD	˜7P°à¡CÅ‰4G»‘›gYP×âóL(ªñü%
Ü>È‡°£dÊ[½ÙÖ öÂ7²$®ÛæÙVÔöù4¹x–ui?w‚2¯ âÁL…ªÿH° -Âíl/kãzJ½E/Má®Dæ™UTıø bÀO¢Ì©d÷[0Ø¢ĞÎã¥Hİ³Í¨¬òè/rà-Aí†neu^?Çƒ’l3k«xûaZDİšÏ_¡ÀÇƒc;J™¼U‹ş;˜PhàqA%‡ŞÅnŸfCWˆó0)¢öÌ7«°ù£È{°¡TÆû•|ZÜ1Ë¤¸Ú’ßnÁg‡RíkoxbMg¯SàéAt†9•s~*ü	F5”¿x‚i/vâ4Oº¡ÇM‘¬dëY{ÖõX<ÒŠì=kz"ÍB­î'fĞVáõG=`#CÉŠ¶>·‡²­eï]`ÌC©ˆ÷01£¦È×²ğ¬#êÉ´¹–tB8‘#eË^¸Æ“—kqz'ÓFê•}~/â]LÍ©¬ôè;s˜+QøæVdôX9Ó—ëpz"ÍG®åa]DÏ›£XÉÓ·é°u¢<Í‹®8ç‘RdïYc×Kñ¸%’ßlÃj‹~:œIo·c³I©µõ½=Œ(&óÔ*úşH±y¦Õ}ş*ü\È1³¤¨ÛòÙ.ÔæøTùmlsh+qú&ÖFô”9{•ZÜÈ,²ê­îdXÑWäğX"ÒÍï¬`êA}†!zÆ•C~Š<‰N5§¼ÒŠï=aF!—Çr’.nçeS\ëÉ{¶µS¼é‰u6=·²'®ÑæåU\üÉ´9¸•cK	º5œ¿H³©öH4³¹©•÷}2¬(êó|(
ñ<&ŠÔ>û„_TÂû,^èÅq$FÛ–ÛvÙ6×¶ò´/ºáEM¯Oá¡DÄ›™[UØÿĞ à@€%İÎ'¤ĞØâÒNî¥eß]ÀÌƒªÿ0 À+‚ø)j÷|2
¬<ë‹z8‘Cf‹U8ı`'BÓë%yŞÅv6G·‘³e©\÷È3³¨¨óğ)"ôÌ8«’ûo`[@ÙÖô9^”Ä{›[XÚÒİîÌgªPıà@ ‚Á…"ÍD­šï_`ÀCŠ<‰f7W°ò /ÂáD-›ïZ`ŞBÅŸ#AÉ†¶µw¾1‡¥İbÎO¥ ßÂÁ„"ÍZ¬ŞêÇaF9”—xr-kïzbME­ŸïAa„F•W|ñ'2Ò®ìåk_xÂd/[àÚBŞÅ'ÓNé¦tÖ:õœ>g«PûàAX„Ñå]^ÌÅ«œûK¸UÿaD	˜7P°à¡CÅ‰4G»‘›gYP×âóL(ªñü%
Ü>È‡°£dÊ[½ÙÖ öÂ7²$®ÛæÙVÔöù4¹x–ui?w‚2¯ âÁL…ªÿH° -Âíl/kãzJ½E/Má®Dæ™UTıø bÀO¢Ì©d÷[0Ø¢ĞÎã¥Hİ³Í¨¬òè/rà-Aí†neu^?Çƒ’l3k«xûaZDİšÏ_¡ÀÇƒc;J™¼U‹ş;˜PhàqA%‡ŞÅnŸfCWˆó0)¢öÌ7«°ù£È{°¡TÆû•|ZÜ1Ë¤¸Ú’ßnÁg‡RíkoxbMg¯SàéAt†9•s~*ü	F5”¿x‚i/vâ4Oº¡ÇM‘¬dëY{ÖõX<ÒŠì=kz"ÍB­î'fĞVáõG=`#CÉŠ¶>·‡²­eï]`ÌC©ˆ÷01£¦È×²ğ¬#êÉ´¹–tB8‘#eË^¸Æ“—kqz'ÓFê•}~/â]LÍ©¬ôè;s˜+QøæVdôX9Ó—ëpz"ÍG®åa]DÏ›£XÉÓ·é°u¢<Í‹®8ç‘RdïYc×Kñ¸%’ßlÃj‹~:œIo·c³I©µõ½=Œ(&óÔ*úşH±y¦Õ}ş*ü\È1³¤¨ÛòÙ.ÔæøTùmlsh+qú&ÖFô”9{•ZÜÈ,²ê­îdXÑWäğX"ÒÍï¬`êA}†!zÆ•C~Š<‰N5§¼ÒŠï=aF!—Çr’.nçeS\ëÉ{¶µS¼é‰u6=·²'®ÑæåU\üÉ´9¸•cK	º5œ¿H³©öH4³¹©•÷}2¬(êó|(
ñ<&ŠÔ>û„_TÂû,^èÅq$FÛ–ÛvÙ6×¶ò´/ºáEM¯Oá¡DÄ›™[UØÿĞ à@€%İÎ'¤ĞØâÒNî¥eß]ÀÌƒªÿ0 À+‚ø)j÷|2
¬<ë‹z8‘Cf‹U8ı`'BÓë%yŞÅv6G·‘³e©\÷È3³¨¨óğ)"ôÌ8«’ûo`[@ÙÖô9^”Ä{›[XÚÒİîÌgªPıà@ ‚Á…"ÍD­šï_`ÀCŠ<‰f7W°ò /ÂáD-›ïZ`ŞBÅŸ#AÉ†¶µw¾1‡¥İbÎO¥ ßÂÁ„"ÍZ¬ŞêÇaF9”—xr-kïzbME­ŸïAa„F•W|ñ'2Ò®ìåk_xÂd/[àÚBŞÅ'ÓNé¦tÖ:õœ>g«PûàAX„Ñå]^ÌÅ«œûK¸UÿaD	˜7P°à¡CÅ‰4G»‘›gYP×âóL(ªñü%
Ü>È‡°£dÊ[½ÙÖ öÂ7²$®ÛæÙVÔöù4¹x–ui?w‚2¯ âÁL…ªÿH° -Âíl/kãzJ½E/Má®Dæ™UTıø bÀO¢Ì©d÷[0Ø¢ĞÎã¥Hİ³Í¨¬òè/rà-Aí†neu^?Çƒ’l3k«xûaZDİšÏ_¡ÀÇƒc;J™¼U‹ş;˜PhàqA%‡ŞÅnŸfCWˆó0)¢öÌ7«°ù£È{°¡TÆû•|ZÜ1Ë¤¸Ú’ßnÁg‡RíkoxbMg¯SàéAt†9•s~*ü	F5”¿x‚i/vâ4Oº¡ÇM‘¬dëY{ÖõX<ÒŠì=kz"ÍB­î'fĞVáõG=`#CÉŠ¶>·‡²­eï]`ÌC©ˆ÷01£¦È×²ğ¬#êÉ´¹–tB8‘#eË^¸Æ“—kqz'ÓFê•}~/â]LÍ©¬ôè;s˜+QøæVdôX9Ó—ëpz"ÍG®åa]DÏ›£XÉÓ·é°u¢<Í‹®8ç‘RdïYc×Kñ¸%’ßlÃj‹~:œIo·c³I©µõ½=Œ(&óÔ*úşH±y¦Õ}ş*ü\È1³¤¨ÛòÙ.ÔæøTùmlsh+qú&ÖFô”9{•ZÜÈ,²ê­îdXÑWäğX"ÒÍï¬`êA}†!zÆ•C~Š<‰N5§¼ÒŠï=aF!—Çr’.nçeS\ëÉ{¶µS¼é‰u6=·²'®ÑæåU\üÉ´9¸•cK	º5œ¿H³©öH4³¹©•÷}2¬(êó|(
ñ<&ŠÔ>û„_TÂû,^èÅq$FÛ–ÛvÙ6×¶ò´/ºáEM¯Oá¡DÄ›™[UØÿĞ à@€%İÎ'¤ĞØâÒNî¥eß]ÀÌƒªÿ0 À+‚ø)j÷|2
¬<ë‹z8‘Cf‹U8ı`'BÓë%yŞÅv6G·‘³e©\÷È3³¨¨óğ)"ôÌ8«’ûo`[@ÙÖô9^”Ä{›[XÚÒİîÌgªPıà@ ‚Á…"ÍD­šï_`ÀCŠ<‰f7W°ò /ÂáD-›ïZ`ŞBÅŸ#AÉ†¶µw¾1‡¥İbÎO¥ ßÂÁ„"ÍZ¬ŞêÇaF9”—xr-kïzbME­ŸïAa„F•W|ñ'2Ò®ìåk_xÂd/[àÚBŞÅ'ÓNé¦tÖ:õœ>g«PûàAX„Ñå]^ÌÅ«œûK¸UÿaD	˜7P°à¡CÅ‰4G»‘›gYP×âóL(ªñü%
Ü>È‡°£dÊ[½ÙÖ öÂ7²$®ÛæÙVÔöù4¹x–ui?w‚2¯ âÁL…ªÿH° -Âíl/kãzJ½E/Má®Dæ™UTıø bÀO¢Ì©d÷[0Ø¢ĞÎã¥Hİ³Í¨¬òè/rà-Aí†neu^?Çƒ’l3k«xûaZDİšÏ_¡ÀÇƒc;J™¼U‹ş;˜PhàqA%‡ŞÅnŸfCWˆó0)¢öÌ7«°ù£È{°¡TÆû•|ZÜ1Ë¤¸Ú’ßnÁg‡RíkoxbMg¯SàéAt†9•s~*ü	F5”¿x‚i/vâ4Oº¡ÇM‘¬dëY{ÖõX<ÒŠì=kz"ÍB­î'fĞVáõG=`#CÉŠ¶>·‡²­eï]`ÌC©ˆ÷01£¦È×²ğ¬#êÉ´¹–tB8‘#eË^¸Æ“—kqz'ÓFê•}~/â]LÍ©¬ôè;s˜+QøæVdôX9Ó—ëpz"ÍG®åa]DÏ›£XÉÓ·é°u¢<Í‹®8ç‘RdïYc×Kñ¸%’ßlÃj‹~:œIo·c³I©µõ½=Œ(&óÔ*úşH±y¦Õ}ş*ü\È1³¤¨ÛòÙ.ÔæøTùmlsh+qú&ÖFô”9{•ZÜÈ,²ê­îdXÑWäğX"ÒÍï¬`êA}†!zÆ•C~Š<‰N5§¼ÒŠï=aF!—Çr’.nçeS\ëÉ{¶µS¼é‰u6=·²'®ÑæåU\üÉ´9¸•cK	º5œ¿H³©öH4³¹©•÷}2¬(êó|(
ñ<&ŠÔ>û„_TÂû,^èÅq$FÛ–ÛvÙ6×¶ò´/ºáEM¯Oá¡DÄ›™[UØÿĞ à@€%İÎ'¤ĞØâÒNî¥eß]ÀÌƒªÿ0 À+‚ø)j÷|2
¬<ë‹z8‘Cf‹U8ı`'BÓë%yŞÅv6G·‘³e©\÷È3³¨¨óğ)"ôÌ8«’ûo`[@ÙÖô9^”Ä{›[XÚÒİîÌgªPıà@ ‚Á…"ÍD­šï_`ÀCŠ<‰f7W°ò /ÂáD-›ïZ`ŞBÅŸ#AÉ†¶µw¾1‡¥İbÎO¥ ßÂÁ„"ÍZ¬ŞêÇaF9”—xr-kïzbME­ŸïAa„F•W|ñ'2Ò®ìåk_xÂd/[àÚBŞÅ'ÓNé¦tÖ:õœ>g«PûàAX„Ñå]^ÌÅ«œûK¸UÿaD	˜7P°à¡CÅ‰4G»‘›gYP×âóL(ªñü%
Ü>È‡°£dÊ[½ÙÖ öÂ7²$®ÛæÙVÔöù4¹x–ui?w‚2¯ âÁL…ªÿH° -Âíl/kãzJ½E/Má®Dæ™UTıø bÀO¢Ì©d÷[0Ø¢ĞÎã¥Hİ³Í¨¬òè/rà-Aí†neu^?Çƒ’l3k«xûaZDİšÏ_¡ÀÇƒc;J™¼U‹ş;˜PhàqA%‡ŞÅnŸfCWˆó0)¢öÌ7«°ù£È{°¡TÆû•|ZÜ1Ë¤¸Ú’ßnÁg‡RíkoxbMg¯SàéAt†9•s~*ü	F5”¿x‚i/vâ4Oº¡ÇM‘¬dëY{ÖõX<ÒŠì=kz"ÍB­î'fĞVáõG=`#CÉŠ¶>·‡²­eï]`ÌC©ˆ÷01£¦È×²ğ¬#êÉ´¹–tB8‘#eË^¸Æ“—kqz'ÓFê•}~/â]LÍ©¬ôè;s˜+QøæVdôX9Ó—ëpz"ÍG®åa]DÏ›£XÉÓ·é°u¢<Í‹®8ç‘RdïYc×Kñ¸%’ßlÃj‹~:œIo·c³I©µõ½=Œ(&óÔ*úşH±y¦Õ}ş*ü\È1³¤¨ÛòÙ.ÔæøTùmlsh+qú&ÖFô”9{•ZÜÈ,²ê­îdXÑWäğX"ÒÍï¬`êA}†!zÆ•C~Š<‰N5§¼ÒŠï=aF!—Çr’.nçeS\ëÉ{¶µS¼é‰u6=·²'®ÑæåU\üÉ´9¸•cK	º5œ¿H³©öH4³¹©•÷}2¬(êó|(
ñ<&ŠÔ>û„_TÂû,^èÅq$FÛ–ÛvÙ6×¶ò´/ºáEM¯Oá¡DÄ›™[UØÿĞ à@€%İÎ'¤ĞØâÒNî¥eß]ÀÌƒªÿ0 À+‚ø)j÷|2
¬<ë‹z8‘Cf‹U8ı`'BÓë%yŞÅv6G·‘³e©\÷È3³¨¨óğ)"ôÌ8«’ûo`[@ÙÖô9^”Ä{›[XÚÒİîÌgªPıà@ ‚Á…"ÍD­šï_`ÀCŠ<‰f7W°ò /ÂáD-›ïZ`ŞBÅŸ#AÉ†¶µw¾1‡¥İbÎO¥ ßÂÁ„"ÍZ¬ŞêÇaF9”—xr-kïzbME­ŸïAa„F•W|ñ'2Ò®ìåk_xÂd/[àÚBŞÅ'ÓNé¦tÖ:õœ>g«PûàAX„Ñå]^ÌÅ«œûK¸UÿaD	˜7P°à¡CÅ‰4G»‘›gYP×âóL(ªñü%
Ü>È‡°£dÊ[½ÙÖ öÂ7²$®ÛæÙVÔöù4¹x–ui?w‚2¯ âÁL…ªÿH° -Âíl/kãzJ½E/Má®Dæ™UTıø bÀO¢Ì©d÷[0Ø¢ĞÎã¥Hİ³Í¨¬òè/rà-Aí†neu^?Çƒ’l3k«xûaZDİšÏ_¡ÀÇƒc;J™¼U‹ş;˜PhàqA%‡ŞÅnŸfCWˆó0)¢öÌ7«°ù£È{°¡TÆû•|ZÜ1Ë¤¸Ú’ßnÁg‡RíkoxbMg¯SàéAt†9•s~*ü	F5”¿x‚i/vâ4Oº¡ÇM‘¬dëY{ÖõX<ÒŠì=kz"ÍB­î'fĞVáõG=`#CÉŠ¶>·‡²­eï]`ÌC©ˆ÷01£¦È×²ğ¬#êÉ´¹–tB8‘#eË^¸Æ“—kqz'ÓFê•}~/â]LÍ©¬ôè;s˜+QøæVdôX9Ó—ëpz"ÍG®åa]DÏ›£XÉÓ·é°u¢<Í‹®8ç‘RdïYc×Kñ¸%’ßlÃj‹~:œIo·c³I©µõ½=Œ(&óÔ*úşH±y¦Õ}ş*ü\È1³¤¨ÛòÙ.ÔæøTùmlsh+qú&ÖFô”9{•ZÜÈ,²ê­îdXÑWäğX"ÒÍï¬`êA}†!zÆ•C~Š<‰N5§¼ÒŠï=aF!—Çr’.nçeS\ëÉ{¶µS¼é‰u6=·²'®ÑæåU\üÉ´9¸•cK	º5œ¿H³©öH4³¹©•÷}2¬(êó|(
ñ<&ŠÔ>û„_TÂû,^èÅq$FÛ–ÛvÙ6×¶ò´/ºáEM¯Oá¡DÄ›™[UØÿĞ à@€%İÎ'¤ĞØâÒNî¥eß]ÀÌƒªÿ0 À+‚ø)j÷|2
¬<ë‹z8‘Cf‹U8ı`'BÓë%yŞÅv6G·‘³e©\÷È3³¨¨óğ)"ôÌ8«’ûo`[@ÙÖô9^”Ä{›[XÚÒİîÌgªPıà@ ‚Á…"ÍD­šï_`ÀCŠ<‰f7W°ò /ÂáD-›ïZ`ŞBÅŸ#AÉ†¶µw¾1‡¥İbÎO¥ ßÂÁ„"ÍZ¬ŞêÇaF9”—xr-kïzbME­ŸïAa„F•W|ñ'2Ò®ìåk_xÂd/[àÚBŞÅ'ÓNé¦tÖ:õœ>g«PûàAX„Ñå]^ÌÅ«œûK¸UÿaD	˜7P°à¡CÅ‰4G»‘›gYP×âóL(ªñü%
Ü>È‡°£dÊ[½ÙÖ öÂ7²$®ÛæÙVÔöù4¹x–ui?w‚2¯ âÁL…ªÿH° -Âíl/kãzJ½E/Má®Dæ™UTıø bÀO¢Ì©d÷[0Ø¢ĞÎã¥Hİ³Í¨¬òè/rà-Aí†neu^?Çƒ’l3k«xûaZDİšÏ_¡ÀÇƒc;J™¼U‹ş;˜PhàqA%‡ŞÅnŸfCWˆó0)¢öÌ7«°ù£È{°¡TÆû•|ZÜ1Ë¤¸Ú’ßnÁg‡RíkoxbMg¯SàéAt†9•s~*ü	F5”¿x‚i/vâ4Oº¡ÇM‘¬dëY{ÖõX<ÒŠì=kz"ÍB­î'fĞVáõG=`#CÉŠ¶>·‡²­eï]`ÌC©ˆ÷01£¦È×²ğ¬#êÉ´¹–tB8‘#eË^¸Æ“—kqz'ÓFê•}~/â]LÍ©¬ôè;s˜+QøæVdôX9Ó—ëpz"ÍG®åa]DÏ›£XÉÓ·é°u¢<Í‹®8ç‘RdïYc×Kñ¸%’ßlÃj‹~:œIo·c³I©µõ½=Œ(&óÔ*úşH±y¦Õ}ş*ü\È1³¤¨ÛòÙ.ÔæøTùmlsh+qú&ÖFô”9{•ZÜÈ,²ê­îdXÑWäğX"ÒÍï¬`êA}†!zÆ•C~Š<‰N5§¼ÒŠï=aF!—Çr’.nçeS\ëÉ{¶µS¼é‰u6=·²'®ÑæåU\üÉ´9¸•cK	º5œ¿H³©öH4³¹©•÷}2¬(êó|(
ñ<&ŠÔ>û„_TÂû,^èÅq$FÛ–ÛvÙ6×¶ò´/ºáEM¯Oá¡DÄ›™[UØÿĞ à@€%İÎ'¤ĞØâÒNî¥eß]ÀÌƒªÿ0 À+‚ø)j÷|2
¬<ë‹z8‘Cf‹U8ı`'BÓë%yŞÅv6G·‘³e©\÷È3³¨¨óğ)"ôÌ8«’ûo`[@ÙÖô9^”Ä{›[XÚÒİîÌgªPıà@ ‚Á…"ÍD­šï_`ÀCŠ<‰f7W°ò /ÂáD-›ïZ`ŞBÅŸ#AÉ†¶µw¾1‡¥İbÎO¥ ßÂÁ„"ÍZ¬ŞêÇaF9”—xr-kïzbME­ŸïAa„F•W|ñ'2Ò®ìåk_xÂd/[àÚBŞÅ'ÓNé¦tÖ:õœ>g«PûàAX„Ñå]^ÌÅ«œûK¸UÿaD	˜7P°à¡CÅ‰4G»‘›gYP×âóL(ªñü%
Ü>È‡°£dÊ[½ÙÖ öÂ7²$®ÛæÙVÔöù4¹x–ui?w‚2¯ âÁL…ªÿH° -Âíl/kãzJ½E/Má®Dæ™UTıø bÀO¢Ì©d÷[0Ø¢ĞÎã¥Hİ³Í¨¬òè/rà-Aí†neu^?Çƒ’l3k«xûaZDİšÏ_¡ÀÇƒc;J™¼U‹ş;˜PhàqA%‡ŞÅnŸfCWˆó0)¢öÌ7«°ù£È{°¡TÆû•|ZÜ1Ë¤¸Ú’ßnÁg‡RíkoxbMg¯SàéAt†9•s~*ü	F5”¿x‚i/vâ4Oº¡ÇM‘¬dëY{ÖõX<ÒŠì=kz"ÍB­î'fĞVáõG=`#CÉŠ¶>·‡²­eï]`ÌC©ˆ÷01£¦È×²ğ¬#êÉ´¹–tB8‘#eË^¸Æ“—kqz'ÓFê•}~/â]LÍ©¬ôè;s˜+QøæVdôX9Ó—ëpz"ÍG®åa]DÏ›£XÉÓ·é°u¢<Í‹®8ç‘RdïYc×Kñ¸%’ßlÃj‹~:œIo·c³I©µõ½=Œ(&óÔ*úşH±y¦Õ}ş*ü\È1³¤¨ÛòÙ.ÔæøTùmlsh+qú&ÖFô”9{•ZÜÈ,²ê­îdXÑWäğX"ÒÍï¬`êA}†!zÆ•C~Š<‰N5§¼ÒŠï=aF!—Çr’.nçeS\ëÉ{¶µS¼é‰u6=·²'®ÑæåU\üÉ´9¸•cK	º5œ¿H³©öH4³¹©•÷}2¬(êó|(
ñ<&ŠÔ>û„_TÂû,^èÅq$FÛ–ÛvÙ6×¶ò´/ºáEM¯Oá¡DÄ›™[UØÿĞ à@€%İÎ'¤ĞØâÒNî¥eß]ÀÌƒªÿ0 À+‚ø)j÷|2
¬<ë‹z8‘Cf‹U8ı`'BÓë%yŞÅv6G·‘³e©\÷È3³¨¨óğ)"ôÌ8«’ûo`[@ÙÖô9^”Ä{›[XÚÒİîÌgªPıà@ ‚Á…"ÍD­šï_`ÀCŠ<‰f7W°ò /ÂáD-›ïZ`ŞBÅŸ#AÉ†¶µw¾1‡¥İbÎO¥ ßÂÁ„"ÍZ¬ŞêÇaF9”—xr-kïzbME­ŸïAa„F•W|ñ'2Ò®ìåk_xÂd/[àÚBŞÅ'ÓNé¦tÖ:õœ>g«PûàAX„Ñå]^ÌÅ«œûK¸UÿaD	˜7P°à¡CÅ‰4G»‘›gYP×âóL(ªñü%
Ü>È‡°£dÊ[½ÙÖ öÂ7²$®ÛæÙVÔöù4¹x–ui?w‚2¯ âÁL…ªÿH° -Âíl/kãzJ½E/Má®Dæ™UTıø bÀO¢Ì©d÷[0Ø¢ĞÎã¥Hİ³Í¨¬òè/rà-Aí†neu^?Çƒ’l3k«xûaZDİšÏ_¡ÀÇƒc;J™¼U‹ş;˜PhàqA%‡ŞÅnŸfCWˆó0)¢öÌ7«°ù£È{°¡TÆû•|ZÜ1Ë¤¸Ú’ßnÁg‡RíkoxbMg¯SàéAt†9•s~*ü	F5”¿x‚i/vâ4Oº¡ÇM‘¬dëY{ÖõX<ÒŠì=kz"ÍB­î'fĞVáõG=`#CÉŠ¶>·‡²­eï]`ÌC©ˆ÷01£¦È×²ğ¬#êÉ´¹–tB8‘#eË^¸Æ“—kqz'ÓFê•}~/â]LÍ©¬ôè;s˜+QøæVdôX9Ó—ëpz"ÍG®åa]DÏ›£XÉÓ·é°u¢<Í‹®8ç‘RdïYc×Kñ¸%’ßlÃj‹~:œIo·c³I©µõ½=Œ(&óÔ*úşH±y¦Õ}ş*ü\È1³¤¨ÛòÙ.ÔæøTùmlsh+qú&ÖFô”9{•ZÜÈ,²ê­îdXÑWäğX"ÒÍï¬`êA}†!zÆ•C~Š<‰N5§¼ÒŠï=aF!—Çr’.nçeS\ëÉ{¶µS¼é‰u6=·²'®ÑæåU\üÉ´9¸•cK	º5œ¿H³©öH4³¹©•÷}2¬(êó|(
ñ<&ŠÔ>û„_TÂû,^èÅq$FÛ–ÛvÙ6×¶ò´/ºáEM¯Oá¡DÄ›™[UØÿĞ à@€%İÎ'¤ĞØâÒNî¥eß]ÀÌƒªÿ0 À+‚ø)j÷|2
¬<ë‹z8‘Cf‹U8ı`'BÓë%yŞÅv6G·‘³e©\÷È3³¨¨óğ)"ôÌ8«’ûo`[@ÙÖô9^”Ä{›[XÚÒİîÌgªPıà@ ‚Á…"ÍD­šï_`ÀCŠ<‰f7W°ò /ÂáD-›ïZ`ŞBÅŸ#AÉ†¶µw¾1‡¥İbÎO¥ ßÂÁ„"ÍZ¬ŞêÇaF9”—xr-kïzbME­ŸïAa„F•W|ñ'2Ò®ìåk_xÂd/[àÚBŞÅ'ÓNé¦tÖ:õœ>g«PûàAX„Ñå]^ÌÅ«œûK¸UÿaD	˜7P°à¡CÅ‰4G»‘›gYP×âóL(ªñü%
Ü>È‡°£dÊ[½ÙÖ öÂ7²$®ÛæÙVÔöù4¹x–ui?w‚2¯ âÁL…ªÿH° -Âíl/kãzJ½E/Má®Dæ™UTıø bÀO¢Ì©d÷[0Ø¢ĞÎã¥Hİ³Í¨¬òè/rà-Aí†neu^?Çƒ’l3k«xûaZDİšÏ_¡ÀÇƒc;J™¼U‹ş;˜PhàqA%‡ŞÅnŸfCWˆó0)¢öÌ7«°ù£È{°¡TÆû•|ZÜ1Ë¤¸Ú’ßnÁg‡RíkoxbMg¯SàéAt†9•s~*ü	F5”¿x‚i/vâ4Oº¡ÇM‘¬dëY{ÖõX<ÒŠì=kz"ÍB­î'fĞVáõG=`#CÉŠ¶>·‡²­eï]`ÌC©ˆ÷01£¦È×²ğ¬#êÉ´¹–tB8‘#eË^¸Æ“—kqz'ÓFê•}~/â]LÍ©¬ôè;s˜+QøæVdôX9Ó—ëpz"ÍG®åa]DÏ›£XÉÓ·é°u¢<Í‹®8ç‘RdïYc×Kñ¸%’ßlÃj‹~:œIo·c³I©µõ½=Œ(&óÔ*úşH±y¦Õ}ş*ü\È1³¤¨ÛòÙ.ÔæøTùmlsh+qú&ÖFô”9{•ZÜÈ,²ê­îdXÑWäğX"ÒÍï¬`êA}†!zÆ•C~Š<‰N5§¼ÒŠï=aF!—Çr’.nçeS\ëÉ{¶µS¼é‰u6=·²'®ÑæåU\üÉ´9¸•cK	º5œ¿H³©öH4³¹©•÷}2¬(êó|(
ñ<&ŠÔ>û„_TÂû,^èÅq$FÛ–ÛvÙ6×¶ò´/ºáEM¯Oá¡DÄ›™[UØÿĞ à@€%İÎ'¤ĞØâÒNî¥eß]ÀÌƒªÿ0 À+‚ø)j÷|2
¬<ë‹z8‘Cf‹U8ı`'BÓë%yŞÅv6G·‘³e©\÷È3³¨¨óğ)"ôÌ8«’ûo`[@ÙÖô9^”Ä{›[XÚÒİîÌgªPıà@ ‚Á…"ÍD­šï_`ÀCŠ<‰f7W°ò /ÂáD-›ïZ`ŞBÅŸ#AÉ†¶µw¾1‡¥İbÎO¥ ßÂÁ„"ÍZ¬ŞêÇaF9”—xr-kïzbME­ŸïAa„F•W|ñ'2Ò®ìåk_xÂd/[àÚBŞÅ'ÓNé¦tÖ:õœ>g«PûàAX„Ñå]^ÌÅ«œûK¸UÿaD	˜7P°à¡CÅ‰4G»‘›gYP×âóL(ªñü%
Ü>È‡°£dÊ[½ÙÖ öÂ7²$®ÛæÙVÔöù4¹x–ui?w‚2¯ âÁL…ªÿH° -Âíl/kãzJ½E/Má®Dæ™UTıø bÀO¢Ì©d÷[0Ø¢ĞÎã¥Hİ³Í¨¬òè/rà-Aí†neu^?Çƒ’l3k«xûaZDİšÏ_¡ÀÇƒc;J™¼U‹ş;˜PhàqA%‡ŞÅnŸfCWˆó0)¢öÌ7«°ù£È{°¡TÆû•|ZÜ1Ë¤¸Ú’ßnÁg‡RíkoxbMg¯SàéAt†9•s~*ü	F5”¿x‚i/vâ4Oº¡ÇM‘¬dëY{ÖõX<ÒŠì=kz"ÍB­î'fĞVáõG=`#CÉŠ¶>·‡²­eï]`ÌC©ˆ÷01£¦È×²ğ¬#êÉ´¹–tB8‘#eË^¸Æ“—kqz'ÓFê•}~/â]LÍ©¬ôè;s˜+QøæVdôX9Ó—ëpz"ÍG®åa]DÏ›£XÉÓ·é°u¢<Í‹®8ç‘RdïYc×Kñ¸%’ßlÃj‹~:œIo·c³I©µõ½=Œ(&óÔ*úşH±y¦Õ}ş*ü\È1³¤¨ÛòÙ.ÔæøTùmlsh+qú&ÖFô”9{•ZÜÈ,²ê­îdXÑWäğX"ÒÍï¬`êA}†!zÆ•C~Š<‰N5§¼ÒŠï=aF!—Çr’.nçeS\ëÉ{¶µS¼é‰u6=·²'®ÑæåU\üÉ´9¸•cK	º5œ¿H³©öH4³¹©•÷}2¬(êó|(
ñ<&ŠÔ>û„_TÂû,^èÅq$FÛ–ÛvÙ6×¶ò´/ºáEM¯Oá¡DÄ›™[UØÿĞ à@€%İÎ'¤ĞØâÒNî¥eß]ÀÌƒªÿ0 À+‚ø)j÷|2
¬<ë‹z8‘Cf‹U8ı`'BÓë%yŞÅv6G·‘³e©\÷È3³¨¨óğ)"ôÌ8«’ûo`[@ÙÖô9^”Ä{›[XÚÒİîÌgªPıà@ ‚Á…"ÍD­šï_`ÀCŠ<‰f7W°ò /ÂáD-›ïZ`ŞBÅŸ#AÉ†¶µw¾1‡¥İbÎO¥ ßÂÁ„"ÍZ¬ŞêÇaF9”—xr-kïzbME­ŸïAa„F•W|ñ'2Ò®ìåk_xÂd/[àÚBŞÅ'ÓNé¦tÖ:õœ>g«PûàAX„Ñå]^ÌÅ«œûK¸UÿaD	˜7P°à¡CÅ‰4G»‘›gYP×âóL(ªñü%
Ü>È‡°£dÊ[½ÙÖ öÂ7²$®ÛæÙVÔöù4¹x–ui?w‚2¯ âÁL…ªÿH° -Âíl/kãzJ½E/Má®Dæ™UTıø bÀO¢Ì©d÷[0Ø¢ĞÎã¥Hİ³Í¨¬òè/rà-Aí†neu^?Çƒ’l3k«xûaZDİšÏ_¡ÀÇƒc;J™¼U‹ş;˜PhàqA%‡ŞÅnŸfCWˆó0)¢öÌ7«°ù£È{°¡TÆû•|ZÜ1Ë¤¸Ú’ßnÁg‡RíkoxbMg¯SàéAt†9•s~*ü	F5”¿x‚i/vâ4Oº¡ÇM‘¬dëY{ÖõX<ÒŠì=kz"ÍB­î'fĞVáõG=`#CÉŠ¶>·‡²­eï]`ÌC©ˆ÷01£¦È×²ğ¬#êÉ´¹–tB8‘#eË^¸Æ“—kqz'ÓFê•}~/â]LÍ©¬ôè;s˜+QøæVdôX9Ó—ëpz"ÍG®åa]DÏ›£XÉÓ·é°u¢<Í‹®8ç‘RdïYc×Kñ¸%’ßlÃj‹~:œIo·c³I©µõ½=Œ(&óÔ*úşH±y¦Õ}ş*ü\È1³¤¨ÛòÙ.ÔæøTùmlsh+qú&ÖFô”9{•ZÜÈ,²ê­îdXÑWäğX"ÒÍï¬`êA}†!zÆ•C~Š<‰N5§¼ÒŠï=aF!—Çr’.nçeS\ëÉ{¶µS¼é‰u6=·²'®ÑæåU\üÉ´9¸•cK	º5œ¿H³©öH4³¹©•÷}2¬(êó|(
ñ<&ŠÔ>û„_TÂû,^èÅq$FÛ–ÛvÙ6×¶ò´/ºáEM¯Oá¡DÄ›™[UØÿĞ à@€%İÎ'¤ĞØâÒNî¥eß]ÀÌƒªÿ0 À+‚ø)j÷|2
¬<ë‹z8‘Cf‹U8ı`'BÓë%yŞÅv6G·‘³e©\÷È3³¨¨óğ)"ôÌ8«’ûo`[@ÙÖô9^”Ä{›[XÚÒİîÌgªPıà@ ‚Á…"ÍD­šï_`ÀCŠ<‰f7W°ò /ÂáD-›ïZ`ŞBÅŸ#AÉ†¶µw¾1‡¥İbÎO¥ ßÂÁ„"ÍZ¬ŞêÇaF9”—xr-kïzbME­ŸïAa„F•W|ñ'2Ò®ìåk_xÂd/[àÚBŞÅ'ÓNé¦tÖ:õœ>g«PûàAX„Ñå]^ÌÅ«œûK¸UÿaD	˜7P°à¡CÅ‰4G»‘›gYP×âóL(ªñü%
Ü>È‡°£dÊ[½ÙÖ öÂ7²$®ÛæÙVÔöù4¹x–ui?w‚2¯ âÁL…ªÿH° -Âíl/kãzJ½E/Má®Dæ™UTıø bÀO¢Ì©d÷[0Ø¢ĞÎã¥Hİ³Í¨¬òè/rà-Aí†neu^?Çƒ’l3k«xûaZDİšÏ_¡ÀÇƒc;J™¼U‹ş;˜PhàqA%‡ŞÅnŸfCWˆó0)¢öÌ7«°ù£È{°¡TÆû•|ZÜ1Ë¤¸Ú’ßnÁg‡RíkoxbMg¯SàéAt†9•s~*ü	F5”¿x‚i/vâ4Oº¡ÇM‘¬dëY{ÖõX<ÒŠì=kz"ÍB­î'fĞVáõG=`#CÉŠ¶>·‡²­eï]`ÌC©ˆ÷01£¦È×²ğ¬#êÉ´¹–tB8‘#eË^¸Æ“—kqz'ÓFê•}~/â]LÍ©¬ôè;s˜+QøæVdôX9Ó—ëpz"ÍG®åa]DÏ›£XÉÓ·é°u¢<Í‹®8ç‘RdïYc×Kñ¸%’ßlÃj‹~:œIo·c³I©µõ½=Œ(&óÔ*úşH±y¦Õ}ş*ü\È1³¤¨ÛòÙ.ÔæøTùmlsh+qú&ÖFô”9{•ZÜÈ,²ê­îdXÑWäğX"ÒÍï¬`êA}†!zÆ•C~Š<‰N5§¼ÒŠï=aF!—Çr’.nçeS\ëÉ{¶µS¼é‰u6=·²'®ÑæåU\üÉ´9¸•cK	º5œ¿H³©öH4³¹©•÷}2¬(êó|(
ñ<&ŠÔ>û„_TÂû,^èÅq$FÛ–ÛvÙ6×¶ò´/ºáEM¯Oá¡DÄ›™[UØÿĞ à@€%İÎ'¤ĞØâÒNî¥eß]ÀÌƒªÿ0 À+‚ø)j÷|2
¬<ë‹z8‘Cf‹U8ı`'BÓë%yŞÅv6G·‘³e©\÷È3³¨¨óğ)"ôÌ8«’ûo`[@ÙÖô9^”Ä{›[XÚÒİîÌgªPıà@ ‚Á…"ÍD­šï_`ÀCŠ<‰f7W°ò /ÂáD-›ïZ`ŞBÅŸ#AÉ†¶µw¾1‡¥İbÎO¥ ßÂÁ„"ÍZ¬ŞêÇaF9”—xr-kïzbME­ŸïAa„F•W|ñ'2Ò®ìåk_xÂd/[àÚBŞÅ'ÓNé¦tÖ:õœ>g«PûàAX„Ñå]^ÌÅ«œûK¸UÿaD	˜7P°à¡CÅ‰4G»‘›gYP×âóL(ªñü%
Ü>È‡°£dÊ[½ÙÖ öÂ7²$®ÛæÙVÔöù4¹x–ui?w‚2¯ âÁL…ªÿH° -Âíl/kãzJ½E/Má®Dæ™UTıø bÀO¢Ì©d÷[0Ø¢ĞÎã¥Hİ³Í¨¬òè/rà-Aí†neu^?Çƒ’l3k«xûaZDİšÏ_¡ÀÇƒc;J™¼U‹ş;˜PhàqA%‡ŞÅnŸfCWˆó0)¢öÌ7«°ù£È{°¡TÆû•|ZÜ1Ë¤¸Ú’ßnÁg‡RíkoxbMg¯SàéAt†9•s~*ü	F5”¿x‚i/vâ4Oº¡ÇM‘¬dëY{ÖõX<ÒŠì=kz"ÍB­î'fĞVáõG=`#CÉŠ¶>·‡²­eï]`ÌC©ˆ÷01£¦È×²ğ¬#êÉ´¹–tB8‘#eË^¸Æ“—kqz'ÓFê•}~/â]LÍ©¬ôè;s˜+QøæVdôX9Ó—ëpz"ÍG®åa]DÏ›£XÉÓ·é°u¢<Í‹®8ç‘RdïYc×Kñ¸%’ßlÃj‹~:œIo·c³I©µõ½=Œ(&óÔ*úşH±y¦Õ}ş*ü\È1³¤¨ÛòÙ.ÔæøTùmlsh+qú&ÖFô”9{•ZÜÈ,²ê­îdXÑWäğX"ÒÍï¬`êA}†!zÆ•C~Š<‰N5§¼ÒŠï=aF!—Çr’.nçeS\ëÉ{¶µS¼é‰u6=·²'®ÑæåU\üÉ´9¸•cK	º5œ¿H³©öH4³¹©•÷}2¬(êó|(
ñ<&ŠÔ>û„_TÂû,^èÅq$FÛ–ÛvÙ6×¶ò´/ºáEM¯Oá¡DÄ›™[UØÿĞ à@€%İÎ'¤ĞØâÒNî¥eß]ÀÌƒªÿ0 À+‚ø)j÷|2
¬<ë‹z8‘Cf‹U8ı`'BÓë%yŞÅv6G·‘³e©\÷È3³¨¨óğ)"ôÌ8«’ûo`[@ÙÖô9^”Ä{›[XÚÒİîÌgªPıà@ ‚Á…"ÍD­šï_`ÀCŠ<‰f7W°ò /ÂáD-›ïZ`ŞBÅŸ#AÉ†¶µw¾1‡¥İbÎO¥ ßÂÁ„"ÍZ¬ŞêÇaF9”—xr-kïzbME­ŸïAa„F•W|ñ'2Ò®ìåk_xÂd/[àÚBŞÅ'ÓNé¦tÖ:õœ>g«PûàAX„Ñå]^ÌÅ«œûK¸UÿaD	˜7P°à¡CÅ‰4G»‘›gYP×âóL(ªñü%
Ü>È‡°£dÊ[½ÙÖ öÂ7²$®ÛæÙVÔöù4¹x–ui?w‚2¯ âÁL…ªÿH° -Âíl/kãzJ½E/Má®Dæ™UTıø bÀO¢Ì©d÷[0Ø¢ĞÎã¥Hİ³Í¨¬òè/rà-Aí†neu^?Çƒ’l3k«xûaZDİšÏ_¡ÀÇƒc;J™¼U‹ş;˜PhàqA%‡ŞÅnŸfCWˆó0)¢öÌ7«°ù£È{°¡TÆû•|ZÜ1Ë¤¸Ú’ßnÁg‡RíkoxbMg¯SàéAt†9•s~*ü	F5”¿x‚i/vâ4Oº¡ÇM‘¬dëY{ÖõX<ÒŠì=kz"ÍB­î'fĞVáõG=`#CÉŠ¶>·‡²­eï]`ÌC©ˆ÷01£¦È×²ğ¬#êÉ´¹–tB8‘#eË^¸Æ“—kqz'ÓFê•}~/â]LÍ©¬ôè;s˜+QøæVdôX9Ó—ëpz"ÍG®åa]DÏ›£XÉÓ·é°u¢<Í‹®8ç‘RdïYc×Kñ¸%’ßlÃj‹~:œIo·c³I©µõ½=Œ(&óÔ*úşH±y¦Õ}ş*ü\È1³¤¨ÛòÙ.ÔæøTùmlsh+qú&ÖFô”9{•ZÜÈ,²ê­îdXÑWäğX"ÒÍï¬`êA}†!zÆ•C~Š<‰N5§¼ÒŠï=aF!—Çr’.nçeS\ëÉ{¶µS¼é‰u6=·²'®ÑæåU\üÉ´9¸•cK	º5œ¿H³©öH4³¹©•÷}2¬(êó|(
ñ<&ŠÔ>û„_TÂû,^èÅq$FÛ–ÛvÙ6×¶ò´/ºáEM¯Oá¡DÄ›™[UØÿĞ à@€%İÎ'¤ĞØâÒNî¥eß]ÀÌƒªÿ0 À+‚ø)j÷|2
¬<ë‹z8‘Cf‹U8ı`'BÓë%yŞÅv6G·‘³e©\÷È3³¨¨óğ)"ôÌ8«’ûo`[@ÙÖô9^”Ä{›[XÚÒİîÌgªPıà@ ‚Á…"ÍD­šï_`ÀCŠ<‰f7W°ò /ÂáD-›ïZ`ŞBÅŸ#AÉ†¶µw¾1‡¥İbÎO¥ ßÂÁ„"ÍZ¬ŞêÇaF9”—xr-kïzbME­ŸïAa„F•W|ñ'2Ò®ìåk_xÂd/[àÚBŞÅ'ÓNé¦tÖ:õœ>g«PûàAX„Ñå]^ÌÅ«œûK¸UÿaD	˜7P°à¡CÅ‰4G»‘›gYP×âóL(ªñü%
Ü>È‡°£dÊ[½ÙÖ öÂ7²$®ÛæÙVÔöù4¹x–ui?w‚2¯ âÁL…ªÿH° -Âíl/kãzJ½E/Má®Dæ™UTıø bÀO¢Ì©d÷[0Ø¢ĞÎã¥Hİ³Í¨¬òè/rà-Aí†neu^?Çƒ’l3k«xûaZDİšÏ_¡ÀÇƒc;J™¼U‹ş;˜PhàqA%‡ŞÅnŸfCWˆó0)¢öÌ7«°ù£È{°¡TÆû•|ZÜ1Ë¤¸Ú’ßnÁg‡RíkoxbMg¯SàéAt†9•s~*ü	F5”¿x‚i/vâ4Oº¡ÇM‘¬dëY{ÖõX<ÒŠì=kz"ÍB­î'fĞVáõG=`#CÉŠ¶>·‡²­eï]`ÌC©ˆ÷01£¦È×²ğ¬#êÉ´¹–tB8‘#eË^¸Æ“—kqz'ÓFê•}~/â]LÍ©¬ôè;s˜+QøæVdôX9Ó—ëpz"ÍG®åa]DÏ›£XÉÓ·é°u¢<Í‹®8ç‘RdïYc×Kñ¸%’ßlÃj‹~:œIo·c³I©µõ½=Œ(&óÔ*úşH±y¦Õ}ş*ü\È1³¤¨ÛòÙ.ÔæøTùmlsh+qú&ÖFô”9{•ZÜÈ,²ê­îdXÑWäğX"ÒÍï¬`êA}†!zÆ•C~Š<‰N5§¼ÒŠï=aF!—Çr’.nçeS\ëÉ{¶µS¼é‰u6=·²'®ÑæåU\üÉ´9¸•cK	º5œ¿H³©öH4³¹©•÷}2¬(êó|(
ñ<&ŠÔ>û„_TÂû,^èÅq$FÛ–ÛvÙ6×¶ò´/ºáEM¯Oá¡DÄ›™[UØÿĞ à@€%İÎ'¤ĞØâÒNî¥eß]ÀÌƒªÿ0 À+‚ø)j÷|2
¬<ë‹z8‘Cf‹U8ı`'BÓë%yŞÅv6G·‘³e©\÷È3³¨¨óğ)"ôÌ8«’ûo`[@ÙÖô9^”Ä{›[XÚÒİîÌgªPıà@ ‚Á…"ÍD­šï_`ÀCŠ<‰f7W°ò /ÂáD-›ïZ`ŞBÅŸ#AÉ†¶µw¾1‡¥İbÎO¥ ßÂÁ„"ÍZ¬ŞêÇaF9”—xr-kïzbME­ŸïAa„F•W|ñ'2Ò®ìåk_xÂd/[àÚBŞÅ'ÓNé¦tÖ:õœ>Cà“Z¼ì¡YÛ!„È€şC0”˜KUw±_’~_/óø2š6wÜnWÀh²uŸpbt_9ò£ïneÊÀAƒ±³–‚D)¨ÄÃ˜»RªÚÏÂiNn‘ÛUÆÉ-‡ÁÑØ˜ãR~R5ßû«\æÿëÌúŒ„Ï¾ósvÊ‡$îşW Â¸ÍUŠîBP ÔrÊ+x%^ëjMÀœÁİÏÂ¹÷Åœ=ÿ½	½0¾¢´Á;½w ÜÈ8Â¢˜üT>K¶†0Ú ëJµŒŠ`Üƒ¤|ëI.‡ï!Dó0êàsïÓØxã/zô*¤ÍÖŸÂr‘Gw)ğ87O˜C£D!·š‚#<á»^«æ8Ú{FÄ‹Ùà÷êLL”›~l¸X¼ä n}WÀ³
™<e½l’®uê°¢°Ö,†*i½B	ºŒ¯-ÓÆ*ú€-ÙšããzS,ñİ¯	I]µú6(0Å¬])ˆµ$"êÉ¢›•3!äõ\Ì(QoÔoÍë›ùí5^’÷O  pò!nbBn¤ÇKGª3¯†ƒ&Èâ}=O½‘¼f¸V¢Âş«Ïo~´¥§çØæ¶ï~2î³v«Vy]Í=»uË ûûx eò^Ğï0`’{_?ò°£yøÕG‚ 2 ]·Uï³QƒãéÍj©a}<>¬E‰Ü7€23™Mg¿f3e­kUKàT@åcøâ7QüôØ\œáÇµ‹ºiÙ2”7ïR÷´jé|4­«í˜îøÈ¡¤„ 9¨ÔÄK¨·À¶°“g\Ó^VÉÆ£UŸ¼w5§=ô½L-ŞßÅòq:q.ÆA(·Ñ‚À9Y¸ïëPVÑí$¾wZ3ŠCôİ	ãK#€ø !óùåµ—¡‘/ÌcšqŸH…³-Şôr<ø÷Rh$şï…T®Èù‡™$İíO«‡#-ú×ßœ¼x¾!¹ó!Ïj¢MĞârÆ+gÔbÔˆöÒ“,Q(‰°-8R¡Ù÷ÍÌöĞÅ$ŠîœRâ&öÀÇ’¡µëÖI6‡%ËïªV@4ù6—k®d¥‚ı¦zç`orw#sÜÙiT²ï9Ş§îã~{$Ø¢¸‘ñWËÂ£M‡á$êïÍ£ú¹-±Û-ëÿH‡ç Sğú«µ³şŸ¿ƒÕKËˆ‰'áRrbIw/Ç¸ì£jıÀ<±¸œ¦øåi‘µÕB§½•¹Ã§©çxe˜{äºËO«:5wŸ ~–6U…ÌÔ;%†ŸÌ` <1¼”§O`•àJú(ápÄç˜³zè+ÁÊ‰3^&ñWâ–fBM¿¬¶C„¡ÖpÌU™ûd,iıE¯ZĞÎÕ$9!èôLøÙQâX~ĞúQ>'şºYÆçâ`Eq¬Z\Èü?ê±\“NM$KÃ¬œÆ+¦<á5u¥àîŸpoâ=TœËr‹,Tş°ÁÊÚÆé!GÈ¢¨üç?Ç² m•OWƒÚ¾fÉ!‡Ìİ(÷Šò~]5ŞÏ¯]Ûÿë1[’c^{	·ùn99¥VêML…›9j¥MÜŸÈr‡4‚ÔoË?ˆaóêZ½¡Ïò$oiJD’Z·=ë¼<½5¿´ÀŒ	€‡zSÇÈˆV¦—•lî×QvÑ»Ó$Ûæèp³„XAôX
Š©º†Ş }ó<…n"PyÓÙDê’Hß3ÍÒŸÀs Gw"÷9¥,ïŞSĞ+$h¸=ĞK6ù‚¦=èL4ß‰Á÷êLLššDl»Y‹áµs >–ÀCnÁP5ÕÌ
Ÿ¦vii&D*i»B	º‡_G¸£¿úƒ,0Ø ãîz[÷X|AY§„¬mö¿ŠSš\Ë)0Z½š×­xz Š`¸ŞpB³*à„ÂëDŞ.^jZ\âìGTïôàÄû–ñø’³ÂkŒ3U¯Sà"^…)[İŞˆ HEÿH:úªÎZ•äLukL8Ÿ/qáå94Ëáˆ±%†é™@Ş¦pu±	ã!\óiÜŠQ÷P¡ÔNÏ(—z·ïÈR—.£TşüOŠé[;öÂ?å‘¤>¡µæŒeR€42¬i%í\6›´7¬$ñä1\é¶æÍgb%{\/}Ğ
Ó"ß}ğ	¶²zhb 1:–ºD Yh4Ÿkd-[1íÎGyŒª¦ÍÇŸ¼w;ÿÌmœØzØ-İßÏó™qj²çm»Aå³íšk›¥.ïä ³S(ÒÉ®‚XÍ¡ØôÓù†f&CäŸj@¼ˆöäÒ‘ÕÌkj I6„ˆ-…Şô:“l;t®†×Åš«ãËwŒ½ÓA«²Jœ¹y‹ ŒòóšÂ ¿úArÅgÚcèxi#[ÿ~5‰‰½ù‡Ææ¡ı÷À¾=¡ºn¯w$ı°RäÜkù$ê>O†‘,VëÇM£‹ê=Ğ)ªuÎ=‘>V—Æg¦~æã‚}±sÚïheBm¾UE¦Úãw{)(ÛÃôEq83½ö¼@¹·£6ú¶,‚Ú”&HéƒK:­¨qÀ+²ÍŸ±r†®lâYYİò“õî%i@CX¸è¢ZüñÌÕÖÏÆ’_ğşB¶LÕÂ£×ú´+Ë;ùG¡?vb2~’6_…Ç.©ÔåÎÔ`)1¬”­NZ•ãJò-âqòB$I+ÁË¿_ğfj_QgBI¾›¶O„­*ìÌY˜Êv&‚G½VÂĞÃ$xª!ëõ~¶ €3±NcÂÙT:©¶…‡"şA1=”–JcŠİÉ6¿óşf£eÅo½V+<ıHäŸq\I¯T–ËxŠZÊAAÛùé*GÃ£ŸıÜ?Ä²¬õ|?ô±?—•µ†ı!¸÷ø„ÌÍºß¨wÁ2´‘t‡³6ş^x÷(óŸkwô„%/îûV4:¦cgF‹3‚rÿ;yì$mêYMÀ‘vs; «SÌVšİnÔUÚ?§è‹w"ó‚e9ó¢˜\$íïåPOÑ´Ó.ÛäéJQIrõ…›H‡å!Có0oPs#q´D¨JÃ¢¸ÿ^¨+íæ‡Lt›YiôC½¼N:I‚9<ê»W«ëÈYq[Ä‹Ùà÷êGL”›}mŒX´á¶r<–À³˜d‡m£_Éô	nõ'}åˆh‰C1º‰uÓá*J\‰íd|l#Úœ…/z²ìgDb­~Ê4´‰ŒÔM»škã¸ Ñô`ûQb%ÄO8ÜPãçV
ïæ—ÂãóC›Ú}Ÿ9ñ¤ï›TÙÌJ™±b/yaÑ½š¼cH;À«¯ÏkeóL;Ÿ!qéx¿Ëú‰0»Ô6ËŒÜÛkgKmˆH—äŞê1_“B_?ó‚¤yşÕ¿İù
 úÅ
a?0²Ÿ3r«ñ|Â;6,.´«ŠÑ9øÃiyÛƒš­…‰ÀJË÷å©¥u ¶Ô÷#b&zm.HĞ Ó"ŞLR{ŞòÛ^btÁPÇÔ/ÉÇ„–ß©ƒÀ²±®’U]íüqÅ¦ª‰ÍËŠw7¥=ñ¼)½¹ƒPóšÁq%÷@·ÙƒóÄjñH=7Š{$" ‚W=Ï¾¶f†o'rä”ú– iéoQÔ$Í\›HŸ«­uÊVàp“n^cöfW%Ëî»T¬ÉÎ”¡Õƒx€#+úÜ/úÓÛMé›EDX’QÎ<bÍ+°½—´‹	EõşH4½ˆ8R åŸRšÌöÕÀ%¿î—RíÜbùx$ë	O‘"WÚ7%Ìï«WxÄ›«H?lÀ^6õªô|Äç:a^rw#sÜÙiT²Ì9û§Åãk{
(ş3!/½'@X*
€ZÜDn‹eYß|øè'}€’AX‘Dà®ÏÑÔpËy¼çÓw7ë’üæˆôëñ¸Ç ?¦ ¯dÕÙÏÉ’_	»ç®ÖÙÆé£Ãû‹+Ë8Ã¥Ê­}#½ı€\Ÿá…Ç.¯ÕßÏà‘PR_İ÷ı$>ÇAJÿ'ïqÿB"¹C¤˜ìï×^$ğen_]ö}¯¾¶N„¥*äÌY™ød.å>áÖ‡rbgÛj‘uôDøh 3°z“4[…`aû	C8Ä‹ĞJˆã HãÁ2³.¥µ•aã¬f¾eÇnWÀmHäu…bxâì_?ò¥é|`;E¯(ÓŞ+né%GÍ¢¨K?Ç²®m,ÃôÂ‘ÛTôÉ%‡È ˆ÷‚,<PKtX¦]Úÿà0d“\^uöóŸkvÊ½%&îû®–3MÛŸËs¿5r¸«xØ$i*6 ïò$ghsE¤«PŞVfMnÒUĞÏÑ“ê[~ëHmƒS8Ï¢”ıh>OlvªŞÂÓ
ÚİéIC¸"¥IëI'†İĞœXtoPqÒ!Øzã$zú*«ÍÚŸÍrŸ|‡Lb›YhÂBŠMAÙ+·šƒ<äºe«çÈP€í4Ó‰ÄµÓL›|m†X·à‡s7gŸ•³™;eµm©^ûô	ny> ’³[ÛéÊGº£¾úˆÜF£È§ƒ8@ ±ñ¢C¬æ™—)Å
\&¾yãˆÙLŸ›yì¶û}Èõgw1‡ÁÌÖ›ömŠ^ó¦oˆÚôvw*Îe‘ÂT€É7†¬&Êâ}<}MÅìGH:ğ«¿ÎY•ãMN›$›&÷Êtz¿k!)å¤,%†è¯AæµJŠ9	%äËòò^å~Û0g“A^ò°£xÄÕu¿ä¢ğ¿’Ziì_[íŸ?r¯Á|>¥´ßŒkWÃøË%í]ı=#e~@ÃO;“…Y,æÉgˆ“uü/tÑ?Òßzñ<¶»òØibw~30}$E˜©ïÅ©À¾°•’P]âüy:	ZÆ§¥şî¥¯ÍœÑzÜ-ÒßÅò z”«³çm»@ı³î›WkÊH…0ÆĞßÔBÈ‚S=Ï¾™¶i|ıÌÓåªkaLŸštoP>%Õu²&éo#SèØCà±pk®ğO½½Ç$úî¸T©5[&{…8NáZ*èF@³~+¹·´Âj¢MÕo3¤áÛ“‹	G“,PØàân}[<ÁD-Pò$ÆöÉü%ºîœRçİSøD%5ê3OaI4†©%Ìï¨VNÅ¢«A5—{®W¢Æe¦qæ.öÍ²»ıÊ
®{Z^ ó¾^µÇˆ@J°©‘Û§«­Èí†ÔÕ¸‚£3ú¹,Û*ëñI%‡ë SVÌ=µHUŸ£s¼¤lçXeàwt€&vha¼7Ö‚ğ;¬¯nÔêÏÉ“¿ h£Er®/ÖÔ=CIVû‚+
Ê!úT˜Ïåb9~’Æ:Ö©~Á»´­ˆıÁİşı+?ù±.—å@r³˜w“»âhg¸ò_ğki^`ö|,#ÜûÜ+ì4Úy•7Õô×>µâŒnF$ˆÉE…Ÿ-W( 3±B“?Z½1XäæÆ`Mp”j]ıJkŠŞÿé¯O”‘wVÆ¦<á7tŸı³IŸq_C_45ÇwŒqÁ@°±³–ƒEX"jY€B6œÄ|>Á±:–£Eï\À9ĞR=ÙÔ[vTâqş8¹*»Ñ·Bî¼;›Å¶%+îûW	Â¸Ì¥ïuP!$£yå$gê]MÊŸ¢v{û™ ÷Ï¦<Ê½¼¿”IcÊ‡hô´ó‚`8Á¢—ım>K¶‚‡Ôâ»—+|âC-¹6T¹jJéC“YHá3ˆªá#q—ƒD¨BÂŸ¹Ï Gvô9¥"îâ£FÛİëâHVqºf«çÈT€ë4ÙˆõşÓLšAl²X¹à‡sf¥dánÈP:%lŸ^ğôZL,Š*hŒC1º‰¯#ÓÆÚ–,;Ø¦ãçzW-Èİ¡øNØ†<)-Ä.¬QÙëåZkz¼ëúI‡/Ñ€‘2jw:»=“S`_ì òœá÷rKvr*Îe‘ÈT€9UëÌB™°“}=IMT¡ŠGjÉe!ó½×.÷Æ7­šöuo?á¿r‡(