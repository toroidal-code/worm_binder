#! /usr/bin/env ruby
# encoding: utf-8

require 'rubygems'
require 'open-uri'
require 'nokogiri'
require 'typhoeus'
require 'gepub'
require 'fileutils'
require 'colorize'
require 'ruby-progressbar'
require 'slop'

$stdout.sync = true
$stderr.sync = true

# Command-line options
opts = Slop.parse do |o|
  o.bool '-s', '--single', 'Compile into single file', default: false
  o.string '-c', '--covers ARTIST', 'sandara, TyrialFrost', default: 'sandara'
  o.bool('--epub2', 'Generate a strict EPUB2 instead of an EPUB3')

  o.bool('-v', '--verbose', 'enable verbose mode')
  o.on '-h', '--help' do
    puts o
    exit
  end
end

# Constants
EPUB2 = opts[:epub2]
VERBOSE = opts[:verbose]
DOCTYPE = if EPUB2 # EPUB2 has a strict DOCTYPE requirement
            '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">'
          else
            '<!DOCTYPE html>'
          end

###################
## MONKEYPATCHES ##
###################

# This converts a ul/li(a,ul/li)/a structure into
# nested maps of chapter titles to URLs (JSON-style)
# e.g.
# [{"Stories (Arcs 21+)"=>
#   [{"Arc 21 (Imago)"=>
#     [{"21.01"=>
#       "https://parahumans.wordpress.com/category/stories-arcs-21/arc-21-imago/21-01/"},
#      {"21.02"=>
#       "https://parahumans.wordpress.com/category/stories-arcs-21/arc-21-imago/21-02/"}]
#    }]
#  }]
class Nokogiri::XML::Node
  def to_native
    case name.to_s
    when 'li'
      kids = children.to_a
      if kids.length == 1
        kids.first.to_native
      elsif kids.length == 2
        # Weird soft-hyphen problem for chapter 10
        Hash[kids.first.text.gsub(/\u00AD/, '').strip, kids.last.to_native]
      end
    when 'ul'
      children.to_a.map(&:to_native)
    when 'a'
      Hash[text.strip, attributes['href'].text]
    end
  end
end

# Remove the weird superheadings and flatten to just Arcs + Epilogue
# Can then be built into Ruby objects or converted to JSON(..)
def remove_large_groupings(root)
  epilogue = root.pop
  newroot = []
  root.map { |la| newroot.push(*la.values.first) } # only a single key/value pair
  newroot << epilogue
  return newroot
end

###############
## MAIN CODE ##
###############

Typhoeus::Config.user_agent = "Worm Binder - Ruby/#{RUBY_VERSION}"
$hydra = Typhoeus::Hydra.new

class Chapter
  @@count = 1
  @idx = 1
  @shortname = ''
  @title = ''
  @url = ''
  @content = ''
  @request = nil

  attr_accessor :idx, :shortname, :url, :content, :request, :title
  
  # {'1.01' => 'https://parahumans.wordpress.com/...'}
  def self.build(obj)
    c = Chapter.new
    c.shortname = obj.keys.first
    c.url = obj.values.first
    c.idx = @@count
    @@count += 1

    c.request = Typhoeus::Request.new(c.url, followlocation: true)
    callback = lambda do |response|
      if response.success?
        body = Nokogiri::HTML(response.body)
        # get title
        c.title = body.css('h1.entry-title').first.text #html formatted
        content = body.css('div.entry-content').first

        # clean
        content.search('.//div').remove
        content.xpath('//@align').remove
        content.xpath('//@draggable').remove
        content.xpath('//@id').remove

        # Replace all external images with alt-text
        content.css('img').each { |img| img.replace img.attr('alt') }

        # Get rid of those pesky prev/next links
        content.css('p a').each do |a|
          if a.text == 'Last Chapter' || a.text == 'Next Chapter'
            a.parent.remove
          end
        end

        # Replace those square characters with horizontal rules
        content.xpath("//p[contains(text(), '\u25A0')]").each { |e| e.replace '<hr/>' }

        # Only collect the paragraphs and horizontal rules
        c.content = content.css('p,hr').to_xhtml

        # Either print out the success message or update the progressbar
        if VERBOSE
          puts "Processed #{c.title}".green
        else
          $progressbar.increment
        end
      else
        $stderr.puts "Couldn't fetch #{c.shortname}. Retrying...".red if VERBOSE
        c.request = Typhoeus::Request.new(c.url, followlocation: true)
        c.request.on_complete(&callback)
        $hydra.queue c.request
      end
    end
    c.request.on_complete(&callback)
    $hydra.queue c.request
    c
  end

  def self.reset_count
    @@count = 1
  end

  def to_s
    @name
  end

  def to_xhtml
    <<XHTML
<?xml version="1.0" encoding="utf-8"?>
#{DOCTYPE}
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en">
  <head><title>c#{idx}</title></head>
  <body>
    #{'<section epub:type="chapter">' unless EPUB2}
      <h1 style="text-align:center">#{@title}</h1>
      #{@content}
    #{'</section>' unless EPUB2}
  </body>
</html>
XHTML
  end
end

# Volumes are a single bound entry in a saga or epic
class Volumes
  Divisions = { 'Skitter' => 0,'Weaver' => 8,'Taylor' => 24 } # zero-indexed

  # THE TyrialFrost COVERS ARE COURTESY OF TyrialFrost ON REDDIT.COM
  JCCovers = ['http://i.imgur.com/r7upMSQ.jpg',
                'http://i.imgur.com/zJXE2oq.jpg',
                'http://i.imgur.com/Z9KSlxo.jpg']

  # THE ENDBRINGERS COVERS ARE THE SOLE PROPERTY OF SANDARA
  Endbringers = ['http://pre05.deviantart.net/1395/th/pre/f/2016/104/c/e/worm___endbringer_leviathan_by_sandara-d9yuupd.jpg',
                   'http://orig04.deviantart.net/8738/f/2016/006/a/a/worm___endbringer_behemoth_by_sandara-d9n1huj.jpg',
                   'http://orig10.deviantart.net/ea69/f/2016/103/6/e/worm___the_simurgh_by_sandara-d9nzjkl.jpg']

  Endbringersrear = ['http://orig03.deviantart.net/61fa/f/2015/280/4/f/the_undersiders_by_imskeptical-d9cb5ui.jpg',
                       'http://orig01.deviantart.net/ac95/f/2016/006/9/c/worm___b_b_and__b_by_sandara-d9lqnx0.jpg',
                       'http://orig08.deviantart.net/9939/f/2016/006/3/4/worm___taylor_by_sandara-d9kb143.jpg']

  # THE MONOLITHIC COVER IS THE SOLE PROPERTY OF CACTUSFANTOSTICO
  Monolithic =  'http://orig08.deviantart.net/9cea/f/2015/051/7/8/worm_cover_by_cactusfantastico-d8ivj4b.png'
  Monolithicrear = 'http://36.media.tumblr.com/cc29794d0050859bf33489472ac6d1a1/tumblr_n8bigjHH5G1s28h8fo1_1280.png'
end

# Story arcs collect chapters under a common title
class StoryArc
  @name = ''
  @idx = 0
  @chapters = []

  attr_accessor :name, :idx, :chapters

  # {'Arc 1 (Gestation)' => [{'1.01' => '...'}, {'1.02' => '...'}]}
  def self.build(obj)
    sa = StoryArc.new
    arcname = obj.keys.first
    chapters = obj.values.first

    if m = arcname.match(/([0-9]+)\s*\(([^\)]*)\)/)       # Try to extract title from Arc XX (...)
      sa.idx = m[1]
      sa.name = m[2]
    elsif m = arcname.match(/\(([^\)]*)\)/)
      sa.idx = 31               # Epilogue is Chapter 31
      sa.name = m[1]
    else
      raise(ArgumentError, "Could not parse Arc: #{arcname}")
    end

    sa.chapters = chapters.map { |ch| Chapter.build(ch) }
    sa
  end

  def to_s
    @name
  end

  def to_xhtml
    <<XHTML
<?xml version="1.0" encoding="utf-8"?>
#{DOCTYPE}
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en">
  <head><title>p#{idx}</title></head>
  <body>
    #{'<section epub:type="part">' unless EPUB2}
      <h1 style="text-align:center">#{@name}</h1>
    #{'</section>' unless EPUB2}
  </body>
</html>
XHTML
  end
end

def create(volume_name, volume_num, storyarcs, start, stop,
           covers, trilogy = true)
  puts "Binding... #{volume_name}".green

  volume = GEPUB::Book.new('OEPBS/package.opf', 'version' => EPUB2 ? '2.0' : '3.0')
  volume.epub_backward_compat = true

  volume.language = 'en'
  volume.primary_identifier("https://parahumans.wordpress.com/#{volume_name}",
                            'BookId', 'URL')

  volume.add_title(volume_name, nil, GEPUB::TITLE_TYPE::MAIN)
  volume.creator = 'J.C. McCrae'

  if trilogy
    volume.metadata
          .add_metadata('title', 'Parahumans Saga', nil)
          .refine('title-type', 'collection')
          .refine('group-position', volume_num.to_s)

    volume.metadata
          .add_metadata('title', "WORM, Book #{volume_num}: #{volume_name}")
          .refine('title-type', 'extended')

    cover_url = covers[volume_num - 1]
  else
    volume.metadata
          .add_metadata('title', 'The Parahumans Saga', nil)
          .refine('title-type', 'subtitile')
          .refine('group-position', volume_num.to_s)

    cover_url = covers
  end

  cover_ext = File.extname(cover_url)
  volume.add_item(format('img/cover_image.%s', cover_ext), open(cover_url).open).cover_image

  coverpage = <<-XHTML
<?xml version="1.0" encoding="utf-8"?>
#{DOCTYPE}
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
  <head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8"/>
    <title>Cover</title>
    <style type="text/css" title="override_css">
      @page { padding: 0pt; margin:0pt }
      body { text-align: center; padding:0pt; margin: 0pt; }
    </style>
  </head>
  <body>
    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" version="1.1" width="100%" height="100%" preserveAspectRatio="xMidYMid meet">
        <image width="100%" height="100%" xlink:href="cover_image.#{cover_ext}"></image>
    </svg>
  </body>
</html>
  XHTML


  volume.ordered do
    volume.add_item('img/coverpage.xhtml')
          .add_content(StringIO.new(coverpage))

    # For each storyarc in the volume
    storyarcs.slice(start..stop).each do |arc|
      volume.add_item("text/part#{arc.idx}.xhtml")
            .add_content(StringIO.new(arc.to_xhtml))
            .toc_text_with_level("Arc #{arc.idx}: #{arc.name}", 1)

      arc.chapters.each do |chapter|
        volume.add_item("text/chapter#{chapter.idx}.xhtml")
              .add_content(StringIO.new(chapter.to_xhtml))
              .toc_text_with_level(chapter.title, 2)
      end
    end
  end

  volume.generate_nav_doc unless EPUB2

  filename = format('Worm %02d - %s.epub', volume_num, volume_name)
  filepath = File.join(File.dirname(__FILE__), filename)
  volume.generate_epub filepath
end

def bind(storyarcs, single, covers)
  if single
    create('Worm', 0, storyarcs, 0, -1, covers, false)
  else
    divisions = Volumes::Divisions
    divisions.map.with_index do |(volume_name, start), idx|
      stop = divisions.values[idx + 1] || 0
      create(volume_name, idx + 1, storyarcs, start, stop - 1, covers)
    end
  end
end

###################################
## Main functionality below here ##
###################################

# Fetch the homepage
xmldoc = Nokogiri::XML(open('https://parahumans.wordpress.com')) do |config|
  config.noblanks
end

ruby_toc = remove_large_groupings(xmldoc.css('#categories-2 ul').first.to_native)
book = ruby_toc.map { |sa| StoryArc.build sa }

# Set up the progress bar unless we're in verbose mode
$progressbar = ProgressBar.create(format: 'Processing Worm...'.green + ' %a [%B] %p%% - (%c/%C)',
                                  progress_mark: '#',
                                  remainder_mark: '-',
                                  total: $hydra.queued_requests.count) unless VERBOSE

$hydra.run

covers =
    if opts[:single]
      Volumes::Monolithic
    else
      case opts[:covers]
      when 'sandara'
        Volumes::Endbringers
      when 'TyrialFrost'
        Volumes::JCCovers
      else
        Volumes::Endbringers
      end
    end

bind book, opts[:single], covers
