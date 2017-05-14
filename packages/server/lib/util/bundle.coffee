_                      = require("lodash")
fs                     = require("fs-extra")
EE                     = require("events")
path                   = require("path")
through                = require("through")
Promise                = require("bluebird")
babelify               = require("babelify")
watchify               = require("watchify")
browserify             = require("browserify")
presetReact            = require("babel-preset-react")
presetLatest           = require("babel-preset-latest")
stringStream           = require("string-to-stream")
pluginAddModuleExports = require("babel-plugin-add-module-exports")
sanitize               = require("sanitize-filename")
cjsxify                = require("./cjsxify")
appData                = require("./app_data")

fs = Promise.promisifyAll(fs)

builtFiles = {}

module.exports = {
  ## for testing purposes
  reset: ->
    builtFiles = {}

  outputPath: (projectName = "", filePath) ->
    appData.path("bundles", sanitize(projectName), filePath)

  build: (filePath, config) ->
    if config.isHeadless and built = builtFiles[filePath]
      return built

    emitter = new EE()

    absolutePath = path.join(config.projectRoot, filePath)

    bundler = browserify({
      entries:      [absolutePath]
      extensions:   [".js", ".jsx", ".coffee", ".cjsx"]
      cache:        {}
      packageCache: {}
    })

    if not config.isHeadless
      @_watching = true ## for testing purposes

      bundler.plugin(watchify, {
        ignoreWatch: [
          "**/.git/**"
          "**/.nyc_output/**"
          "**/.sass-cache/**"
          "**/bower_components/**"
          "**/coverage/**"
          "**/node_modules/**"
        ]
      })

    bundle = =>
      new Promise (resolve, reject) =>
        outputPath = @outputPath(config.projectName, filePath)
        ## TODO: only ensure directory when first run and not on updates?
        fs.ensureDirAsync(path.dirname(outputPath))
        .then =>
          bundler
          .bundle()
          .on "error", (err) =>
            if config.isHeadless
              err.filePath = absolutePath
              ## backup the original stack before its
              ## potentially modified from bluebird
              err.originalStack = err.stack
              reject(err)
            else
              stringStream(@clientSideError(err))
              .pipe(fs.createWriteStream(outputPath))

              ## TODO: do we need to wait for the 'end'
              ## event here before resolving?
              resolve()
          .on "end", ->
            resolve()
          .pipe(fs.createWriteStream(outputPath))

    bundler
    .transform(cjsxify)
    .transform(babelify, {
      ast: false
      babelrc: false
      plugins: [pluginAddModuleExports]
      presets: [presetLatest, presetReact]
    })
    ## necessary for enzyme
    ## https://github.com/airbnb/enzyme/blob/master/docs/guides/browserify.md
    ## TODO: push this into userland through configuration?
    .external([
      "react/addons"
      "react/lib/ReactContext"
      "react/lib/ExecutionEnvironment"
    ])

    bundler.on "update", (filePaths) ->
      latestBundle = bundle().then ->
        for updatedFilePath in filePaths
          emitter.emit("update", updatedFilePath)
        return

    latestBundle = bundle()

    return builtFiles[filePath] = {
      ## set to empty function in the case where we
      ## are not watching the bundle
      close: bundler.close ? ->

      getLatestBundle: -> latestBundle

      addChangeListener: (onChange) ->
        emitter.on "update", onChange
    }

  errorMessage: (err = {}) ->
    (err.stack ? err.annotated ? err.message ? err.toString())
    ## strip out stack noise from parser like
    ## at Parser.pp$5.raise (/path/to/node_modules/babylon/lib/index.js:4215:13)
    .replace(/\n\s*at.*/g, "")
    .split("From previous event:\n").join("")
    .split("From previous event:").join("")

  clientSideError: (err) ->
    err = @errorMessage(err)
    ## \n doesn't come through properly so preserve it so the
    ## runner can do the right thing
    .replace(/\n/g, '{newline}')
    ## babel adds syntax highlighting for the console in the form of
    ## [90m that need to be stripped out or they appear in the error message
    .replace(/\[\d{1,3}m/g, '')

    """
    (function () {
      Cypress.trigger("script:error", {
        type: "BUNDLE_ERROR",
        error: #{JSON.stringify(err)}
      })
    }())
    """

}
