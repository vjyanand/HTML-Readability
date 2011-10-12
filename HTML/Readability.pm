package HTML::Readability;

use strict;
use Encode qw(encode decode encode_utf8);
use HTML::TreeBuilder;
use Data::Dumper;
use POSIX qw(floor);
use HTML::Entities;
use utf8;

my $charset = 'utf-8';

sub new {
   my $self  = {};
   $self->{url}   = undef;
   $self->{html}   = undef;
   $self->{title}   = undef;
   $self->{dom_tree} = undef;
   $self->{iframeLoads} = 0;
   $self->{rversion} = '1.7.1';
   $self->{frameHack} = 0;
   $self->{trim} = '^\s+|\s+$';
   $self->{replaceFonts} = '<(\/?)font[^>]*>';
   $self->{unlikelyCandidates} = 'combx|comment|community|disqus|extra|foot|header|menu|remark|rss|shoutbox|sidebar|sponsor|ad-break|agegate|pagination|pager|popup|tweet|twitter|yom-edp';
   $self->{okMaybeItsACandidate} = 'and|article|body|column|main|shadow';
   $self->{positive} = 'article|body|content|entry|hentry|main|page|pagination|post|text|blog|story';
   $self->{negative} = 'combx|comment|com-|contact|foot|footer|footnote|masthead|media|meta|outbrain|promo|related|scroll|shoutbox|sidebar|sponsor|shopping|tags|widget';
   $self->{divToPElements} = '<(a|blockquote|dl|div|img|ol|p|pre|table|ul)';
   $self->{replaceBrs} = '(<br[^>]*>[ \n\r\t]*){2,}';
   $self->{normalize} = '\s{2,}';
   $self->{displayNone} = 'display:\s*none;?';
   $self->{killBreaks} = '(<br\s*\/?>(\s|&nbsp;?)*){1,}';
   $self->{video} = 'http:\/\/(www\.)?(youtube|vimeo)\.com';
   $self->{skipFootnoteLink} = '^\s*(\[?[a-z0-9]{1,2}\]?|^|edit|citation needed)\s*$';
   $self->{FLAG_STRIP_UNLIKELYS} = 1;
   $self->{FLAG_WEIGHT_CLASSES} = 2;
   $self->{FLAG_CLEAN_CONDITIONALLY} = 4;
   $self->{flags} = 1 | 2 | 4;
   $self->{attribName} = 'docE1';
   $self->{attribNamecs} = 'docE1s';
   $self->{articleContent} = undef;
   bless($self); 
   return $self;
}
   
sub url {
   my $self = shift;
   if (@_) { $self->{url} = shift }
   return $self->{url};
}

sub html {
   my $self = shift;
   if (@_) { $self->{html} = shift }
   return $self->{html};
}

sub getDOM {
   my $self = shift;
   return $self->{dom_tree};
}

sub initDoc {
   my $self = shift;
   $self->{dom_tree} = HTML::TreeBuilder->new();
   $self->{dom_tree}->ignore_elements(qw(script style));
   $self->{dom_tree}->parse($self->{html});
   $self->{dom_tree}->eof();
   $self->prepDocument();
   $self->getArticleTitle();
   $self->grabArticle();
}

sub prepDocument {
   my $self = shift;
   my $innerHTML = $self->innerHTML($self->{dom_tree}->find_by_tag_name('body'));
   my $len = length($innerHTML);
   $innerHTML =~ s/$self->{replaceBrs}/<\/p><p>/gi;
   $innerHTML =~ s/$self->{replaceFonts}/<$1span>/gi;   
   if ($len != length($innerHTML)) {
     $self->{dom_tree}->find_by_tag_name('body')->delete_content; 
     $self->{dom_tree}->find_by_tag_name('body')->push_content (HTML::TreeBuilder->new_from_content($innerHTML)->look_down(qw!_tag body!)->detach_content);
   }
}

sub getFinalContent {
   my $self = shift;
   my $finalString = $self->{articleContent}->as_HTML();
   $charset = 'utf-8' unless $charset ;
   return $finalString;
}

sub grabArticle {
   my $self = shift;
   #$self->dumpme();
   #exit;
   my $stripUnlikelyCandidates = $self->flagIsActive($self->{FLAG_STRIP_UNLIKELYS});
   my $node = undef;
   my @nodesToScore = ();
   my @eles = $self->{dom_tree}->look_down(sub{ 1 });

   for (my $nodeIndex = 0; $nodeIndex < scalar(@eles); $nodeIndex++ ) {
      my $ele = $eles[$nodeIndex];  
      next unless($ele);

      if ($stripUnlikelyCandidates) {
         my $unlikelyMatchString = $ele->attr('class') . $ele->attr('id');
         if(($unlikelyMatchString =~ m/$self->{unlikelyCandidates}/ig)  && 
               ($unlikelyMatchString !~ m/$self->{okMaybeItsACandidate}/ig) &&  ($ele->tag() ne 'body') ) {
            $ele->delete();
            $nodeIndex--;
            next;
         }
      }
      
      if ($ele->tag() eq 'p' || $ele->tag() eq 'td' || $ele->tag() eq 'pre') {
         push @nodesToScore, $ele;
      }
      
      if ($ele->tag() eq 'div') {
         my $tmpVal = $self->innerHTML($ele);
         if ($tmpVal !~ m/$self->{divToPElements}/i) {
            $ele->tag('p');
            $nodeIndex--;
            push @nodesToScore, $ele; #PROBLEM
         } else {
            $ele->objectify_text();
            my @childNodes = $ele->content_list();
            for(my $j=0; $j < scalar(@childNodes); $j++) {
               my $childNode = $childNodes[$j];
               if (ref($childNode) && ($childNode->tag() eq '~text')) { #TEXTNODE
                  my $newElement = HTML::Element->new('p');
                  $newElement->push_content($childNode->attr('text'));
                  $childNode->replace_with($newElement)->delete();
               }
            }
            $ele->deobjectify_text();
         }
      }
   }
   
   my @candidates = undef;
   for(my $pt = 0; $pt < scalar(@nodesToScore); $pt++) {
      my $node = $nodesToScore[$pt];
      next unless (ref($node) eq 'HTML::Element');
      
      my $parentNode = $node->parent();
      my $grandParentNode = undef;
      if (ref($parentNode) eq 'HTML::Element') {
         $grandParentNode = $parentNode->parent();
      } else {
         next;
      }
      my $innerText = $self->getInnerText($nodesToScore[$pt]);
            
      next if(length($innerText) < 25);
      
      if ($parentNode && !$parentNode->attr($self->{attribNamecs})) {
          $self->initializeNode($parentNode);
          push @candidates, $parentNode; 
      }
      
      if ($grandParentNode && !$grandParentNode->attr($self->{attribNamecs})) {
          $self->initializeNode($grandParentNode);
          push @candidates, $grandParentNode; 
      }

      my $contentScore = 1;
      my @splitVal = split /,/, $innerText;
      $contentScore += scalar(@splitVal);
      @splitVal = undef;
      my $tVal = floor(length($innerText) / 100);
      $contentScore += ($tVal < 3) ? $tVal : 3;
      $parentNode->attr( $self->{attribNamecs}, ($parentNode->attr($self->{attribNamecs}) + $contentScore)) if (ref $parentNode);
      $grandParentNode->attr( $self->{attribNamecs}, ($grandParentNode->attr($self->{attribNamecs}) + $contentScore / 2)) if (ref $grandParentNode);
   }
   
   my $topCandidate = undef;
   for (my $c = 0; $c < scalar(@candidates); $c++) {
      next unless (ref($candidates[$c]) eq 'HTML::Element');
      $candidates[$c]->attr($self->{attribNamecs}, ($candidates[$c]->attr($self->{attribNamecs}) *  (1 - $self->getLinkDensity($candidates[$c]))));     
      if(!$topCandidate || $candidates[$c]->attr($self->{attribNamecs}) > $topCandidate->attr($self->{attribNamecs})) {
         $topCandidate = $candidates[$c]; 
      }
   }
   if (!$topCandidate || $topCandidate->tag eq "body") {
      $topCandidate = HTML::Element->new('div', 'id'=>'docDiv');
      $topCandidate = ($self->{dom_tree}->find('body'));
   }
   
   my $articleContent = HTML::Element->new('div', 'id'=>'docE1');
   my $siblingScoreThreshold = ($topCandidate->attr($self->{attribNamecs} * 0.2 ) > 10) ? ($topCandidate->attr($self->{attribNamecs} * 0.2 )) : 10;
  
   $topCandidate->parent()->objectify_text();
   my @siblingNodes = $topCandidate->parent()->content_list();
   
   for(my $s = 0; $s < scalar(@siblingNodes); $s++) {
      my $siblingNode = $siblingNodes[$s];
      my $append = 0;

      if (ref($siblingNode) && ($siblingNode->tag() eq '~text')) { #TEXTNODE
         my $newElement = HTML::Element->new('p');
         $newElement->push_content($siblingNode->attr('text'));
         $siblingNode->replace_with($newElement)->delete();
      }
 
      if($topCandidate->same_as($siblingNode)) { # REVISIT
         $append = 1;
      }
      my $contentBonus = 0;

      if (($siblingNode->attr('class') eq $topCandidate->attr('class')) && $topCandidate->attr('class')) {
         $contentBonus += $siblingNode->attr($self->{attribNamecs}) * 0.2;
      }
      
      if($siblingNode->attr($self->{attribNamecs}) + $contentBonus >= $siblingScoreThreshold) {
         $append = 1;
      }
      
      if($siblingNode->tag() eq "p") {
      
         my $linkDensity = $self->getLinkDensity($siblingNode);
         my $nodeContent = $self->getInnerText($siblingNode);
         my $nodeLength  = length($nodeContent);
         if($nodeLength > 80 && $linkDensity < 0.25) {
            $append = 1;
         } elsif ($nodeLength < 80 && $linkDensity == 0 && $nodeContent =~ m/\.( |$)/) {
            $append = 1;
         }
      }
      if ($append) {
         my $nodeToAppend = undef;
         if ($siblingNode->tag ne "div" and $siblingNode->tag ne "p") {
            $siblingNode->tag('div');
            $nodeToAppend = $siblingNode;
         } else {
            $nodeToAppend = $siblingNode;
         }
         $siblingNode->attr('class','');
         $articleContent->push_content($nodeToAppend);
      }
   }
   $topCandidate->parent()->deobjectify_text();
   $self->prepArticle($articleContent);
}

sub prepArticle {
   my $self = shift;
   my $articleContent = shift;
   $self->cleanStyles($articleContent);
   
   $self->killBreaks($articleContent);
   $self->clean($articleContent, 'form');
   $self->clean($articleContent, 'object');
   $self->clean($articleContent, 'h1');
   $self->clean($articleContent, 'iframe');
   if(scalar($articleContent->find_by_tag_name('h2')) == 1) {
            #readability.clean(articleContent, "h2"); 
   }
   #TODO
   $self->cleanHeaders($articleContent);
   $self->cleanConditionally($articleContent, 'table');
   $self->cleanConditionally($articleContent, 'ul');
   $self->cleanConditionally($articleContent, 'div');
   #$self->dumpme($articleContent);
   my @articleParagraphs = $articleContent->find_by_tag_name('p');
   for (my $i = (scalar(@articleParagraphs) - 1); $i >=0 ; $i--) {
      my $imgCount = () = $articleParagraphs[$i]->find_by_tag_name('img');
      my $embedCount = () = $articleParagraphs[$i]->find_by_tag_name('embed');
      my $objectCount = () = $articleParagraphs[$i]->find_by_tag_name('object');
      if($imgCount == 0 && $embedCount == 0 && $objectCount == 0 && !$self->getInnerText($articleParagraphs[$i], 0)) {
         $articleParagraphs[$i]->delete;
      }
     
   }
   
   my $innerHTML = $self->innerHTML($articleContent);
   if ($innerHTML =~ m/<br[^>]*>\s*<p/gi) {
      $innerHTML =~ s/<br[^>]*>\s*<p/<p/gi ;
      $self->innerHTML($articleContent, $innerHTML);
   }
   $self->{articleContent} = $articleContent;
}

sub cleanConditionally {
   my $self = shift;
   my $node = shift;
   my $tag = shift;
   return unless ($self->flagIsActive($self->{FLAG_CLEAN_CONDITIONALLY}));

   my @tagsList = reverse ($node->find_by_tag_name($tag));
   my $curTagsLength = scalar(@tagsList);
     
   for (my $i = $curTagsLength - 1; $i >= 0; $i--) {
      my $weight = $self->getClassWeight($tagsList[$i]);
      my $contentScore = ($tagsList[$i]->attr($self->{attribNamecs})) ? $tagsList[$i]->attr($self->{attribNamecs}) : 0;
      if($weight + $contentScore < 0) {
         $tagsList[$i]->delete();
      } elsif ($self->getCharCount($tagsList[$i], ',') < 10) {
         my @t = $tagsList[$i]->find_by_tag_name("p");
         my $p = scalar(@t);
         @t = $tagsList[$i]->find_by_tag_name("img");
         my $img = scalar(@t);
         @t = $tagsList[$i]->find_by_tag_name("input");
         my $input = scalar(@t);
         @t = $tagsList[$i]->find_by_tag_name("li");
         my $li = scalar(@t);
         $li = $li - 100;

         my $embedCount = 0;
         my @embeds = $tagsList[$i]->find_by_tag_name("embed");
         for(my $j=0; $j < scalar(@embeds); $j++) {
            if ($embeds[$j]->attr('src') =~ m/$self->{videos}/i) {
               $embedCount++; 
            }
         }
         #TODO
         my $linkDensity = $self->getLinkDensity($tagsList[$i]);
         my $contentLength = length($self->getInnerText($tagsList[$i]));
         my $toRemove = 0;
         if ( $img > $p ) {
            $toRemove = 1;
         } elsif (($li > $p) and ($tag ne "ul") and ($tag ne "ol")) {
            $toRemove = 1;
         } elsif ($input > floor($p/3) ) {
            $toRemove = 1; 
         } elsif($contentLength < 25 && ($img == 0 || $img > 2) ) {
            $toRemove = 1;
         } elsif($weight < 25 && $linkDensity > 0.2) {
            $toRemove = 1;
         } elsif($weight >= 25 && $linkDensity > 0.5) {
            $toRemove = 1;
         } elsif(($embedCount == 1 && $contentLength < 75) || $embedCount > 1) {
            $toRemove = 1;
         }
         if($toRemove) {
            $tagsList[$i]->delete();
         }
      }
   }
}

sub getCharCount {
   my $self = shift;
   my $node = shift;
   my $tag = shift || ',';
   my $inText = $self->getInnerText($node);
   my @t = split /$tag/ , $inText;
   return (scalar(@t) - 1);
}
    
sub cleanHeaders {
   my $self = shift;
   my $node = shift;
   for (my $headerIndex = 1; $headerIndex < 7; $headerIndex++) {
      my @headers = $node->find_by_tag_name('h' . $headerIndex);
      @headers = reverse (@headers);
      for (my $i = 0; $i < scalar(@headers); $i++) {
         if ($self->getClassWeight($headers[$i]) < 0 || $self->getLinkDensity($headers[$i]) > 0.33) {
            $headers[$i]->delete;
         }
      }
   }
}
    
sub clean {
   my $self = shift;
   my $node = shift;
   my $tag = shift;
   my @eles = reverse($node->find_by_tag_name($tag));
   return unless @eles;
   my $isEmbed = ($tag eq 'object' or $tag == 'embed');
   for(my $i=0; $i < scalar(@eles); $i++) {
      if ($isEmbed) {
         my %attrs = $eles[$i]->all_external_attr();
         my $attributeValues = join ('|', values(%attrs));
         if ($attributeValues =~ /$self->{video}/i ) {
            next;
         }
         if ($self->innerHTML($eles[$i]) =~ /$self->{video}/i ) {
            next;
         }
      }
      $eles[$i]->delete();
   }        
}

sub killBreaks {
   my $self = shift;
   my $node = shift;
   my $innerHTML = $self->innerHTML($node);
   if ($innerHTML =~ m/$self->{killBreaks}/gi) {
      $innerHTML =~ s/$self->{killBreaks}/<br \/>/gi;
      $self->innerHTML($node, $innerHTML);
   }
}

sub cleanStyles {
   my $self = shift;
   my $node = shift;
   my @eles = $node->look_down(sub{ 1 });
   foreach my $ele (@eles) {
      $ele->attr('style', undef);
   }        
}

sub cTextToNode {
   my $self = shift;
   my $text = shift;
   my $parent = shift;
   my $dom = HTML::TreeBuilder->new()->parse_content('<p>'. $text. '</p>');
   $dom->{_content}[1]->{_parent} = $parent;
   $dom = $dom->{_content}[1]->{_content};
   $dom = $dom->[0];
   #print Dumper($dom);
   #exit;
   return $dom;
}

sub getLinkDensity {
   my $self = shift;
   my $node = shift;
   my @links = $node->find('a');
   my $textLength = length($self->getInnerText($node));
   my $linkLength = 0;
   return 0 unless $textLength;
   for(my $i=0; $i < scalar(@links); $i++) {
      $linkLength += length($self->getInnerText($links[$i]));
   }       
   return ($linkLength / $textLength);
}

sub initializeNode {
   my $self = shift;
   my $node = shift;
   $node->attr($self->{attribName}, -1);
   $node->attr($self->{attribNamecs}, "0.0");
   if ($node->tag eq 'div') {
      $node->attr( $self->{attribNamecs}, ($node->attr($self->{attribNamecs}) + 5));
   } elsif ($node->tag eq 'td' || $node->tag eq 'pre' || $node->tag eq 'blockquote') {
       $node->attr( $self->{attribNamecs}, ($node->attr($self->{attribNamecs}) + 3));   
   } elsif ($node->tag eq 'address' || $node->tag eq 'ol' || $node->tag eq 'ul' || $node->tag eq 'dl' || $node->tag eq 'dd' || $node->tag eq 'dt' || $node->tag eq 'form' || $node->tag eq 'li' ) {
       $node->attr( $self->{attribNamecs}, ($node->attr($self->{attribNamecs}) - 3));   
   } elsif ($node->tag eq 'h1' || $node->tag eq 'h2' || $node->tag eq 'h3' || $node->tag eq 'h4' || $node->tag eq 'h5' || $node->tag eq 'h6' || $node->tag eq 'th') {
       $node->attr( $self->{attribNamecs}, ($node->attr($self->{attribNamecs}) - 5));   
   } 

   $node->attr( $self->{attribNamecs}, ($node->attr($self->{attribNamecs}) +  $self->getClassWeight($node)));  
}


sub getClassWeight {
   my $self = shift;
   my $node = shift;

   return 0 unless($self->flagIsActive($self->{FLAG_WEIGHT_CLASSES}));
   my $weight = 0;
   my $tmpvar = $node->attr('class');
   if ($tmpvar) {
      if($tmpvar =~ m/$self->{negative}/i) {
         $weight -= 25; 
      }
      if($tmpvar =~ m/$self->{positive}/i) {
         $weight += 25; 
      }
   }
   my $tmpvar = $node->attr('id');
   if ($tmpvar) {
      if($tmpvar =~ m/$self->{negative}/i) {
         $weight -= 25; 
      }
      if($tmpvar =~ m/$self->{positive}/i) {
         $weight += 25; 
      }
   }
   return $weight;
}

sub getInnerText {
   my $self = shift;
   my $node = shift;
   my $normalizeSpaces = shift || 1;
   my $tmpVal = $node->as_text(skip_dels => 1);
   $tmpVal =~ s/$self->{trim}//g;
   if ($normalizeSpaces) {
      $tmpVal =~ s/$self->{normalize}/ /g;   
   }
   return $tmpVal;
}

sub flagIsActive {
   my $self = shift;
   return ($self->{flags} & shift);
}

sub innerHTML() {
   my $self = shift;
   my $node = shift;
   my $html = shift;
   return undef unless $node;
   
   if ($html) {
      #$node->{_content} = [$self->_fromHTML($html)];
      $node->delete_content;
      $node->push_content(
               HTML::TreeBuilder->new_from_content(
                  $html
               )->look_down(qw!_tag body!)->detach_content
            );
      return;
   }
   my $old = join '', map { (ref($_) eq 'HTML::Element') ? substr( $_->as_HTML('',''),0,-1 ) : '' } $node->content_list ; 
}

sub _fromHTML {
    my ($class, $html) = @_;
    my $dom;
    if ($html =~ /^\s*<html.*?>.*<\/html>\s*\z/is) {
        $dom = HTML::TreeBuilder->new()->parse_content($html);
        return $dom;
    }
    $dom = HTML::TreeBuilder->new()->parse_content('<dummy>' . $html . '</dummy>');
    my @dom = map {
        if (ref($_)) {
            delete $_->{_parent};
        }
        $_;
    } @{$dom->{_body}{_content} || [$dom->{_content}[-1]]};
    return wantarray ? @dom : $dom[0];
}


sub getArticleTitle {
   my $self = shift;
   my $tmpVal = $self->{dom_tree}->find('title');
   my $curTitle = "No title";
   if($tmpVal) {
      $curTitle = $tmpVal->as_trimmed_text();
      $tmpVal = undef;
      my $origTitle = $curTitle;
      if ($curTitle =~ m/ [\|\-] /) {
         $curTitle =~ s/(.*)[\|\-] .*/$1/gi ;
         if ( (split / /, $curTitle) < 3) {
            $curTitle = $origTitle;
            $curTitle =~ s/[^\|\-]*[\|\-](.*)/$1/gi;
         }
      } elsif ($curTitle =~ m/.*:(.*)/) {
         $curTitle =~ s/.*:(.*)/$1/i;
         my @tmpVal = split / /, $curTitle;
         if(scalar(@tmpVal) < 3) {
            $curTitle = $origTitle;
            $curTitle =~ s/[^:]*[:](.*)/$1/i;
         }
      } elsif (length($curTitle) > 150 || length($curTitle) < 15 ) {
         my @tmpVal = $self->{dom_tree}->find('h1');
         if (scalar(@tmpVal) == 1) {
            $curTitle = $tmpVal[0]->as_trimmed_text();   
         }
      }
      $curTitle =~ s/$self->{trim}//gi;
      if( (split / /, $curTitle) <= 4) {
         $curTitle = $origTitle;
      }
   }
   $self->{title} = $curTitle;
}

sub getTitle {
   my $self = shift;
   return $self->{title};
}

sub getHTML {
   my $self = shift;
   use LWP::UserAgent;
   my $ua = LWP::UserAgent->new;
   $ua->agent('Mozilla/5.0 (Windows; U; Windows NT 6.1; en-US) AppleWebKit/533.9 (KHTML, like Gecko) Chrome/6.0.400.0 Safari/533.9');
   $ua->cookie_jar({ file => "/tmp/cookies.txt" });
   my $response = $ua->get($self->url());
   if ($response->is_success && (($response->content_type ne 'image/gif') && ($response->content_type ne 'application/pdf'))) {
      $self->html($response->decoded_content);
      $charset = $response->content_charset;
   } else {
      print("An error happened: \n");
   }
}

sub dumpme {
   my $self = shift;
   my $node = shift;
   my $tmpVal = $node || $self->{dom_tree};
   print $tmpVal->as_HTML('','');
}

sub uri_split {
   my $self = shift;
   my $uri = $self->{url};
   return $uri =~ m,(?:([^:/?#]+):)?(?://([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?,;
}

1
