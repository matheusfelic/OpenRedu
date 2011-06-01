class Seminar < ActiveRecord::Base
  include AASM
  # Lectureable que representa um objeto multimídia simples, podendo ser aúdio,
  # vídeo ou mídia externa (e.g youtube).

  # Utilizado na validação
  #FIXME mover par arquivos de configuração
  SUPPORTED_VIDEOS = [ 'application/x-mp4',
    'video/x-flv',
    'application/x-flv',
    'video/mpeg',
    'video/quicktime',
    'video/x-la-asf',
    'video/x-ms-asf',
    'video/x-msvideo',
    'video/x-sgi-movie',
    'video/x-flv',
    'flv-application/octet-stream',
    'video/3gpp',
    'video/3gpp2',
    'video/3gpp-tt',
    'video/BMPEG',
    'video/BT656',
    'video/CelB',
    'video/DV',
    'video/H261',
    'video/H263',
    'video/H263-1998',
    'video/H263-2000',
    'video/H264',
    'video/JPEG',
    'video/MJ2',
    'video/MP1S',
    'video/MP2P',
    'video/MP2T',
    'video/mp4',
    'video/MP4V-ES',
    'video/MPV',
    'video/mpeg4',
    'video/mpeg',
    'video/avi',
    'video/mpeg4-generic',
    'video/nv',
    'video/vnd.objectvideo',
    'video/parityfec',
    'video/pointer',
    'video/raw',
    'video/rtx' ]

  SUPPORTED_AUDIO = ['audio/mpeg', 'audio/mp3']

  # Video convertido
  has_attached_file :media, Redu::Application.config.video_transcoded
  # Video original. Mantido para caso seja necessário refazer o transcoding
  has_attached_file :original, {}.merge(Redu::Application.config.video_original)

  # Callbacks
  before_create :truncate_youtube_url

  has_one :lecture, :as => :lectureable

  # Maquina de estados do processo de conversão
  aasm_column :state

  aasm_initial_state :waiting

  aasm_state :waiting
  aasm_state :converting, :enter => :transcode
  aasm_state :converted
  aasm_state :failed

  aasm_event :convert do
    transitions :to => :converting, :from => [:waiting]
  end

  aasm_event :ready do
    transitions :to => :converted, :from => [:waiting, :converting]
  end

  aasm_event :fail do
    transitions :to => :failed, :from => [:converting]
  end

  # Habilita diferentes validações dependendo do tipo
  validates_presence_of :external_resource, :if => :external?
  validates_presence_of :external_resource_type, :if => :external?

  validates_presence_of :original, :unless => :external?
  validates_attachment_presence :original, :unless => :external?
  validate :accepted_content_type, :unless => :external?
  validates_attachment_size :original, :less_than => 100.megabytes,
    :unless => :external?

  def validate_youtube_url
    if self.valid? and external_resource_type.eql?('youtube')
      capture = external_resource.scan(/youtube\.com\/watch\?v=([A-Za-z0-9._%-]*)[&\w;=\+_\-]*/)[0]
      errors.add(:external_resource, "Link inválido") unless capture
    end
  end
  # Retorna parâmetro da URL que identifica unicamente o vídeo
  def truncate_youtube_url
      if self.external_resource_type.eql?('youtube')
        capture = self.external_resource.scan(/youtube\.com\/watch\?v=([A-Za-z0-9._%-]*)[&\w;=\+_\-]*/)[0][0]
        # TODO criar validacao pra essa url
        self.external_resource = capture
      end
  end

  # Converte o video para FLV (Zencoder)
  def transcode
    return if Rails.env.development?
    seminar_info = {
      :id => self.id,
      :class => self.class.to_s.tableize,
      :attachment => 'medias',
      :style => 'original',
      :basename => self.original_file_name.split('.')[0],
      :extension => 'flv'
    }

    video_storage = Redu::Application.config.video_transcoded
    output_path = "s3://" + video_storage[:bucket] + "/" + interpolate(video_storage[:path], seminar_info)

    credentials = Redu::Application.config.zencoder_credentials
    config = Redu::Application.config.zencoder
    config[:input] = self.original.url
    config[:output][:url] = output_path
    config[:output][:thumbnails][:base_url] = File.dirname(output_path)
    config[:output][:notifications][:url] = "http://#{credentials[:username]}:#{credentials[:password]}@www.redu.com.br/jobs/notify"

    response = Zencoder::Job.create(config)
    puts response.inspect
    if response.success?
      self.job = response.body["id"]
    else
      self.fail!
    end
  end

  def video?
    SUPPORTED_VIDEOS.include?(self.original_content_type)
  end

  def audio?
    SUPPORTED_AUDIO.include?(self.original_content_type)
  end

  def external?
    self.external_resource_type == "youtube"
  end

  def type
    if video?
      self.original_content_type
    else
      self.external_resource_type
    end
  end

  def need_transcoding?
    (self.video? or self.audio?) && self.waiting?
  end

  # Verifica se o curso tem espaço suficiente para o arquivo
  def can_upload_multimedia?(lecture)
    return true if self.external_resource_type == "youtube"
    return false unless lecture.subject.space.course.plan.active?
    plan = lecture.subject.space.course.plan
    quota = lecture.subject.space.course.quota
    if quota.multimedia > plan.video_storage_limit
      return false
    else
      return true
    end
  end

  protected
  # Deriva o content type olhando diretamente para o arquivo. Workaround para
  # problemas decorrentes da integração uploadify/rails
  # http://github.com/alainbloch/uploadify_rails
  # Deve ser chamado antes de salvar
  def define_content_type
    self.original_content_type = MIME::Types.type_for(self.original_file_name).to_s
  end

  def interpolate(text, mapping)
    mapping.each do |k,v|
      text = text.gsub(':'.concat(k.to_s), v.to_s)
    end
    return text
  end

  # Workaround: Valida content type setado pelo método define_content_type
  def accepted_content_type
    self.errors.add(:original, "Formato inválido") unless video? or audio?
  end
end
