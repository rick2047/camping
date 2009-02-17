# == About Camping::Server
# It is the tiny server for hosting tiny camping apps. It uses rack to do all the heavy lifting and serves camping apps on +WEBrick+ ,+Mongrel+ and an +irb+ consol.
# For an example of usage see the camping startup script.
require 'irb'
require 'rack'
require 'camping/reloader'

# 
# Base class for camping server.
#
class Camping::Server
  attr_reader :reloader
  attr_accessor :conf
# 
# Makes a new Camping::Server object (kinda goes without saying doesn't it??). Excepts two arguments
  # * +conf+ configuration information from the file supplied. (The startup script reads them from ~/.campingrc). It is actually an Hash.
  # * +paths+ paths for server,port number and localhost
  def initialize(conf, paths)
    @conf = conf
    @paths = paths
    @reloader = Camping::Reloader.new
    connect(@conf.database) if @conf.database
  end
 # 
  # Connects to the database configuration hash provided in +db+ 
  def connect(db)
    unless Camping.autoload?(:Models)
      Camping::Models::Base.establish_connection(db)
    end
  end
  # Finds and updates the reloader with new apps added in the current directory. So we get hot plug ins by just moving the app script to the current directories.
  def find_scripts
    scripts = @paths.map do |path|
      case
      when File.file?(path)
        path
      when File.directory?(path)
        Dir[File.join(path, '*.rb')]
      end
    end.flatten.compact
    @reloader.update(*scripts)
  end
  # Default Index page. If more than one apps are loaded this page is rendered and it lists all the apps with links to there source.
  def index_page(apps)
    welcome = "You are Camping"
    header = <<-HTML
<html>
  <head>
    <title>#{welcome}</title>
    <style type="text/css">
      body { 
        font-family: verdana, arial, sans-serif; 
        padding: 10px 40px; 
        margin: 0; 
      }
      h1, h2, h3, h4, h5, h6 {
        font-family: utopia, georgia, serif;
      }
    </style>
  </head>
  <body>
    <h1>#{welcome}</h1>
    HTML
    footer = '</body></html>'
    main = if apps.empty?
      "<p>Good day.  I'm sorry, but I could not find any Camping apps."\
      "You might want to take a look at the console to see if any errors"\
      "have been raised</p>"
    else
      "<p>Good day.  These are the Camping apps you've mounted.</p><ul>" + 
      apps.map do |mount, app|
        "<li><h3 style=\"display: inline\"><a href=\"/#{mount}\">#{app}</a></h3><small> / <a href=\"/code/#{mount}\">View source</a></small></li>"
      end.join("\n") + '</ul>'
    end
    
    header + main + footer
  end
  
  def app
    reload!
    all_apps = apps
    rapp = case all_apps.length
    when 0
      proc{|env|[200,{'Content-Type'=>'text/html'},index_page([])]}
    when 1
      apps.values.first
    else
      hash = {
        "/" => proc {|env|[200,{'Content-Type'=>'text/html'},index_page(all_apps)]}
      }
      all_apps.each do |mount, wrapp|
        # We're doing @reloader.reload! ourself, so we don't need the wrapper.
        app = wrapp.app
        hash["/#{mount}"] = app
        hash["/code/#{mount}"] = proc do |env|
          [200,{'Content-Type'=>'text/plain','X-Sendfile'=>wrapp.script.file},'']
        end
      end
      Rack::URLMap.new(hash)
    end
    rapp = Rack::ContentLength.new(rapp)
    rapp = Rack::Lint.new(rapp)
    rapp = XSendfile.new(rapp)
    rapp = Rack::ShowExceptions.new(rapp)
  end
#  Returns a Hash of all the apps available in the scripts, where the key would be the name of the app (the one you gave to Camping.goes) and the value would be the app (wrapped inside App).
  def apps
    @reloader.apps.inject({}) do |h, (mount, wrapp)|
      h[mount.to_s.downcase] = wrapp
      h
    end
  end
  
  def call(env)
    app.call(env)
  end
  # Starts the camping server with the appropriate serving app.
  def start
    handler, conf = case @conf.server
    when "console"
      puts "** Starting console"
      reload!
      this = self; eval("self", TOPLEVEL_BINDING).meta_def(:reload!) { this.reload!; nil }
      ARGV.clear
      IRB.start
      exit
    when "mongrel"
      puts "** Starting Mongrel on #{@conf.host}:#{@conf.port}"
      [Rack::Handler::Mongrel, {:Port => @conf.port, :Host => @conf.host}]
    when "webrick"
      puts "** Starting WEBrick on #{@conf.host}:#{@conf.port}"
      [Rack::Handler::WEBrick, {:Port => @conf.port, :BindAddress => @conf.host}]
    end
    
    handler.run(self, conf) 
  end
  # Reloads the server with new apps added after the server was started.
  def reload!
    find_scripts
    @reloader.reload!
  end

  # A Rack middleware for reading X-Sendfile. Should only be used in
  # development.
  class XSendfile
  
    HEADERS = [
      "X-Sendfile",
      "X-Accel-Redirect",
      "X-LIGHTTPD-send-file"
    ]
  
    def initialize(app)
      @app = app
    end

    def call(env)
      status, headers, body = @app.call(env)
      headers = Rack::Utils::HeaderHash.new(headers)
      if header = HEADERS.detect { |header| headers.include?(header) }
        path = headers[header]
        body = File.read(path)
        headers['Content-Length'] = body.length.to_s
      end
      [status, headers, body]
    end
  end    
end
