module Procodile
  #
  # This class is responsible for determining which application should be used
  #
  class AppDetermination
    @app_id : Int32?
    @given_root : String?

    @root : String?
    @procfile : String? = nil
    getter root, procfile

    # Start by creating an determination ased on the root and procfile that has been provided
    # to us by the user (from --root and/or --procfile)
    def initialize(
      @pwd : String,
      given_root : String?,
      @given_procfile : String?,
      @global_options : Config::Option = Config::Option.new
    )
      @given_root = given_root ? expand_path(given_root, pwd) : nil

      calculate
    end

    # No root
    def ambiguous?
      !@root
    end

    private def calculate : Nil
      # Try and find something using the information that has been given to us by the user
      find_root_and_procfile(@pwd, @given_root, @given_procfile)

      # Otherwise, try and use the global config we have been given
      find_root_and_procfile_from_options(@global_options) if ambiguous?
    end

    private def find_root_and_procfile(pwd : String, given_root : String?, given_procfile : String?) : String?
      case
      when given_root && given_procfile
        # The user has provided both the root and procfile, we can use these
        @root = expand_path(given_root)
        @procfile = expand_path(given_procfile, @root)
      when given_root && given_procfile.nil?
        # The user has given us a root, we'll use that as the root
        @root = expand_path(given_root)
      when given_root.nil? && given_procfile
        # The user has given us a procfile but no root. We will assume the procfile
        # is in the root of the directory
        @procfile = expand_path(given_procfile)
        @root = File.dirname(@procfile.not_nil!)
      else
        # The user has given us nothing. We will check to see if there's a Procfile
        # in the root of our current pwd
        if File.file?(File.join(pwd, "Procfile"))
          # If there's a procfile in our current pwd, we'll use our current
          # directory as the root.
          @root = pwd
          @procfile = "Procfile"
          @in_app_directory = true
        end
      end

      @root
    end

    private def expand_path(path : String, root : String? = nil) : String
      # Remove trailing slashes for normalization
      path = path.rstrip('/')

      if path.starts_with?('/')
        # If the path starts with a /, it's absolute. Do nothing.
        path
      else
        # Otherwise, if there's a root provided, it should be from the root
        # of that otherwise from the root of the current directory.
        root ? File.join(root, path) : File.join(@pwd, path)
      end
    end

    private def find_root_and_procfile_from_options(options : Config::Option) : String?
      case options
      when Config::Option
        # Use the current hash
        find_root_and_procfile(@pwd, options.root, options.procfile)
      when Array(Config::Option)
        # Global options is provides a list of apps. We need to know which one of
        # these we should be looking at.

        raise Error.new "Still not support pass array yet."
        # FIXME: Still not work
        # find_root_and_procfile_from_options(options.app_id)
      end
    end
  end
end
