$( "#bbcode_enable_all" ).click(function() {
  $('.setting_bbcode input[type=checkbox]').prop('checked', true);
});

$( "#bbcode_disable_all" ).click(function() {
  $('.setting_bbcode input[type=checkbox]').prop('checked', false);
});