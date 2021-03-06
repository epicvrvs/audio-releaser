require 'mp3info'
require 'zlib'
require 'thread'
require 'fileutils'

require 'nil/file'
require 'nil/console'

require 'audio-releaser/Configuration'
require 'audio-releaser/NFOTemplate'

class AudioReleaser
  def initialize(configuration = Configuration)
    @configuration = configuration
    @mutex = Mutex.new
  end

  def scenifyString(string, lowerCase = false)
    output = string.gsub(' ', '_')
    if lowerCase
      output.downcase!
    end
    return output
  end

  def getTrackNumberString(track)
    return sprintf('%02d', track.trackNumber)
  end

  def getMP3Filename(track)
    trackNumberString = getTrackNumberString(track)
    mp3Filename = scenifyString("#{trackNumberString}-#{track.artist}-#{track.title}-#{@configuration::GroupInitials}.mp3", true)
    return mp3Filename
  end

  def getFLACFilename(track)
    return "#{getTrackNumberString(track)} - #{track.artist} - #{track.title}.flac"
  end

  def encodeWAV(track, mode)
    case mode
    when :mp3
      mp3Filename = getMP3Filename(track)
      outputPath = Nil.joinPaths(@mp3OutputDirectory, mp3Filename)
      commandLine = @configuration::MP3EncoderCommandLine
      performHashing = true
    when :flac
      flacFilename = getFLACFilename(track)
      outputPath = Nil.joinPaths(@flacOutputDirectory, flacFilename)
      commandLine = @configuration::FLACEncoderCommandLine
      performHashing = false
    end
    replacementMap = {
      'input' => track.wavPath,
      'output' => outputPath,
      'title' => track.title,
      'artist' => track.artist,
      'album' => @release.title,
      'year' => @release.year.to_s,
      'comment' => @configuration::GroupInitials,
      'trackNumber' => track.trackNumber.to_s,
      'genre' => @release.genre,
    }
    commandLine
    replacementMap.each do |target, replacement|
      actualTarget = "$#{target}$"
      commandLine = commandLine.gsub(actualTarget, replacement)
    end
    `#{commandLine}`
    if performHashing
      hash = getCRC32(outputPath)
      @mutex.synchronize do
        @hashes[mp3Filename] = hash
      end
    end
  end

  def encoderThread
    while true
      track = nil
      @mutex.synchronize do
        if @jobs.empty?
          return
        end
        track = @jobs.shift
      end
      Nil.threadPrint "Processing #{track.wavPath}"
      encodeWAV(track, :mp3)
      encodeWAV(track, :flac)
    end
  end

  def getZeroBasePath(extension)
    fileName = "00-#{@baseReleaseString.downcase}.#{extension}"
    return Nil.joinPaths(@mp3OutputDirectory, fileName)
  end

  def processRelease(release)
    beginning = Time.now
    @release = release
    flacDirectory = "#{release.artist} - #{release.title} (#{release.year})"
    @flacOutputDirectory = Nil.joinPaths(@configuration::FLACReleaseDirectory, flacDirectory)
    @baseReleaseString = scenifyString("#{release.artist}-#{release.title}-#{release.year}-#{@configuration::GroupInitials}")
    @mp3OutputDirectory = Nil.joinPaths(@configuration::MP3ReleaseDirectory, @baseReleaseString)
    [@flacOutputDirectory, @mp3OutputDirectory].each do |directory|
      puts "Creating #{directory}" if !File.exists?(directory)
      FileUtils.mkdir_p(directory)
    end
    copyCover
    createJobs
    createM3U
    encodeWAVFiles
    createSFV
    createNFO
    duration = Time.now - beginning
    printf("Duration: %.2f s\n", duration)
  end

  def createJobs
    @jobs = []
    trackNumber = 1
    @release.tracks.each do |track|
      if !File.exists?(track.wavPath)
        raise "Unable to find WAV: #{track.wavPath}"
      end
      track.trackNumber = trackNumber
      @jobs << track
      trackNumber += 1
    end
  end

  def encodeWAVFiles
    threads = []
    @hashes = {}
    @configuration::WorkerCount.times do
      thread = Thread.new do
        encoderThread
      end
      threads << thread
    end
    threads.each do |thread|
      thread.join
    end
  end

  def copyCover
    FileUtils.cp(@release.coverPath, getZeroBasePath('jpg'))
  end

  def createM3U
    output = ";#{@baseReleaseString}\r\n"
    @jobs.each do |track|
      output += "#{getMP3Filename(track)}\r\n"
    end
    m3uPath = getZeroBasePath('m3u')
    Nil.writeFile(m3uPath, output)
  end

  def getMP3Duration(path)
    Mp3Info.open(path) do |mp3|
      return mp3.length.round
    end
  end

  def getDateString(date)
    return sprintf('%d-%02d-%02d', date.year, date.month, date.day)
  end

  def getTrackData
    trackUnits = []
    trackNumber = 1
    totalTime = 0
    @release.tracks.each do |track|
      track = track.dup
      track.trackNumber = trackNumber
      mp3Filename = getMP3Filename(track)
      mp3Path = Nil.joinPaths(@mp3OutputDirectory, mp3Filename)
      duration = getMP3Duration(mp3Path)
      totalTime += duration
      trackNumberString = sprintf('%02d', trackNumber)
      trackUnits << [trackNumberString, track.title, getDurationString(duration)]
      trackNumber += 1
    end
    totalTimeString = getDurationString(totalTime)
    return trackUnits, totalTimeString
  end

  def getDurationString(duration)
    secondsPerMinute = 60
    minutes = duration / secondsPerMinute
    seconds = duration % secondsPerMinute
    durationString = sprintf('%02d:%02d', minutes, seconds)
    return durationString
  end

  def createNFO
    template = NFOTemplate.new(@configuration::NFOTemplatePath)
    nfoOutputPath = getZeroBasePath('nfo')
    trackData = getTrackData
    fields = {
      'artist' => @release.artist,
      'release' => @release.title,
      'genre' => @release.genre,
      'label' => @release.label,
      'retail date' => getDateString(@release.retailDate),
      'release date' => getDateString(@release.releaseDate),
      'encoder' => @configuration::MP3EncoderName,
      'notes' => @release.notes,
      'tracks' => trackData,
    }
    template.writeNFO(nfoOutputPath, fields)
  end

  def getCRC32(path)
    contents = Nil.readFile(path)
    hashString = '%08x' % Zlib.crc32(contents)
  end

  def createSFV
    output = ";#{@baseReleaseString}\r\n"
    @release.tracks.each do |track|
      fileName = getMP3Filename(track)
      hash = @hashes[fileName]
      if hash == nil
        raise "Unable to retrieve the CRC32 hash for #{fileName}"
      end
      output += "#{fileName} #{hash}\r\n"
    end
    sfvPath = getZeroBasePath('sfv')
    Nil.writeFile(sfvPath, output)
  end
end
